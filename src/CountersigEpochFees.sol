// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./CountersigIdentity.sol";

/**
 * @title CountersigEpochFees
 * @notice On-chain fee registry that gates inclusion in the oracle's reputation
 *         scoring epoch (tokenomics v0.3 §4 "Oracle Epoch Prioritization" + §6
 *         three-stage fee routing).
 *
 *         Operators or querying applications prepay $CSIG toward an agent's epoch
 *         coverage. Each epoch, the oracle charges one `epochFee` per agent it
 *         scores. Agents without coverage fall out of the active scoring run
 *         (best-effort); the free `meetsThreshold()` read on CountersigReputation
 *         is unaffected — the fee gates the *write*, not the read.
 *
 *         Charged fees accumulate in `collected` and are swept by distributeFees()
 *         per the current governance stage:
 *           Bootstrap  -> 100% reward pool,  0% burn
 *           Transition ->  80% reward pool, 20% burn
 *           Mature     ->  50% reward pool, 50% burn
 *
 *         `epochFee` is USD-targeted and governance-tunable (§5); setting it to 0
 *         disables gating entirely (useful on testnet), so chargeEpoch is a no-op
 *         that always reports "covered."
 */
contract CountersigEpochFees is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// Granted to the oracle wallet(s) authorized to charge epochs.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum Stage { Bootstrap, Transition, Mature }

    // -------------------------------------------------------------------------
    // Storage — append-only. New variables must be declared AFTER all existing
    // ones so a UUPS upgrade never shifts the base slot of the `balance` mapping
    // (see the storage-layout test).
    // -------------------------------------------------------------------------

    IERC20 public csig;                          // slot 0
    CountersigIdentity public identityRegistry;  // slot 1
    address public rewardPool;                   // slot 2 — validator/oracle reward destination
    uint256 public epochFee;                     // slot 3 — $CSIG charged per epoch inclusion
    Stage public stage;                          // slot 4
    uint256 public collected;                    // slot 5 — charged fees awaiting distribution
    mapping(bytes32 => uint256) public balance;  // slot 6 — didHash => prepaid $CSIG

    address internal constant BURN_ADDRESS = address(0xdead);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event FeesDeposited(bytes32 indexed didHash, address indexed from, uint256 amount, uint256 newBalance);
    event FeesWithdrawn(bytes32 indexed didHash, address indexed operator, uint256 amount);
    event EpochCharged(bytes32 indexed didHash, uint256 amount, uint256 remaining);
    event FeesDistributed(uint256 toRewardPool, uint256 burned, Stage stage);
    event EpochFeeUpdated(uint256 newFee);
    event StageUpdated(Stage newStage);
    event RewardPoolUpdated(address newRewardPool);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotOperator(bytes32 didHash, address caller);
    error InsufficientBalance(bytes32 didHash, uint256 requested, uint256 available);
    error NothingToDistribute();

    // -------------------------------------------------------------------------
    // Constructor / Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin             DEFAULT_ADMIN_ROLE + UPGRADER_ROLE (governance timelock on mainnet).
     * @param oracle            Initial ORACLE_ROLE holder. Pass address(0) to grant later.
     * @param csigToken         $CSIG ERC20.
     * @param identityRegistry_ CountersigIdentity proxy (for operator checks on withdraw).
     * @param rewardPool_       Destination for the validator/oracle share of fees.
     * @param epochFee_         Initial $CSIG charged per epoch inclusion (0 = gating disabled).
     */
    function initialize(
        address admin,
        address oracle,
        address csigToken,
        address identityRegistry_,
        address rewardPool_,
        uint256 epochFee_
    ) external initializer {
        if (
            admin == address(0) || csigToken == address(0)
                || identityRegistry_ == address(0) || rewardPool_ == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        if (oracle != address(0)) _grantRole(ORACLE_ROLE, oracle);

        csig = IERC20(csigToken);
        identityRegistry = CountersigIdentity(identityRegistry_);
        rewardPool = rewardPool_;
        epochFee = epochFee_;
        stage = Stage.Bootstrap;
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    /**
     * @notice Prepay epoch fees toward an agent's coverage.
     * @dev    Permissionless funder — operators or querying applications may top up
     *         any agent (§4). Caller must approve this contract for `amount` first.
     */
    function depositFor(bytes32 didHash, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        csig.safeTransferFrom(msg.sender, address(this), amount);
        balance[didHash] += amount;
        emit FeesDeposited(didHash, msg.sender, amount, balance[didHash]);
    }

    /**
     * @notice Withdraw unspent prepaid fees. Only the agent's operator may withdraw.
     * @dev    Anyone can fund, but only the operator can pull — a stranger's deposit
     *         cannot be siphoned back out by that stranger.
     */
    function withdraw(bytes32 didHash, uint256 amount) external nonReentrant {
        CountersigIdentity.AgentIdentity memory id = identityRegistry.getIdentity(didHash);
        if (id.operator != msg.sender) revert NotOperator(didHash, msg.sender);
        if (amount == 0) revert ZeroAmount();

        uint256 bal = balance[didHash];
        if (amount > bal) revert InsufficientBalance(didHash, amount, bal);

        balance[didHash] = bal - amount;
        csig.safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(didHash, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Oracle charging
    // -------------------------------------------------------------------------

    /// @notice True if the agent has enough prepaid balance to cover one epoch.
    function isCovered(bytes32 didHash) public view returns (bool) {
        return epochFee == 0 || balance[didHash] >= epochFee;
    }

    /**
     * @notice Charge one epochFee for including the agent in the scoring run.
     * @dev    Oracle-only. Returns false (does NOT revert) when the agent is
     *         uncovered, so the oracle can treat it as best-effort and skip. When
     *         epochFee == 0 gating is disabled: always returns true, charges nothing.
     * @return charged True if the agent was covered and the fee was taken.
     */
    function chargeEpoch(bytes32 didHash) external onlyRole(ORACLE_ROLE) returns (bool charged) {
        uint256 fee = epochFee;
        if (fee == 0) return true;

        uint256 bal = balance[didHash];
        if (bal < fee) return false;

        balance[didHash] = bal - fee;
        collected += fee;
        emit EpochCharged(didHash, fee, balance[didHash]);
        return true;
    }

    // -------------------------------------------------------------------------
    // Distribution
    // -------------------------------------------------------------------------

    /**
     * @notice Sweep collected fees: the reward-pool share to `rewardPool`, the
     *         burn share to 0xdead, split per the current stage. Permissionless —
     *         destinations are fixed, so no liveness dependence on any one party.
     */
    function distributeFees() external nonReentrant {
        uint256 amount = collected;
        if (amount == 0) revert NothingToDistribute();
        collected = 0;

        uint256 burnAmt = (amount * _burnBps(stage)) / 10_000;
        uint256 poolAmt = amount - burnAmt;

        if (poolAmt > 0) csig.safeTransfer(rewardPool, poolAmt);
        if (burnAmt > 0) csig.safeTransfer(BURN_ADDRESS, burnAmt);

        emit FeesDistributed(poolAmt, burnAmt, stage);
    }

    /// @dev Burn share in basis points for each governance stage (§6).
    function _burnBps(Stage s) internal pure returns (uint256) {
        if (s == Stage.Transition) return 2_000; // 20%
        if (s == Stage.Mature) return 5_000;      // 50%
        return 0;                                 // Bootstrap
    }

    // -------------------------------------------------------------------------
    // Admin (governance timelock on mainnet)
    // -------------------------------------------------------------------------

    function setEpochFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        epochFee = newFee;
        emit EpochFeeUpdated(newFee);
    }

    function setStage(Stage newStage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stage = newStage;
        emit StageUpdated(newStage);
    }

    function setRewardPool(address newRewardPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRewardPool == address(0)) revert ZeroAddress();
        rewardPool = newRewardPool;
        emit RewardPoolUpdated(newRewardPool);
    }

    // -------------------------------------------------------------------------
    // UUPS upgrade authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
