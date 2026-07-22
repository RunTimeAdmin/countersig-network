// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./CountersigIdentity.sol";
import "./CountersigReputation.sol";

/**
 * @title CountersigStaking
 * @notice Manages $CSIG bonds for registered agents and enforces the slashing model.
 *
 * Slashing model (testnet: multisig committee):
 *   - A SLASHING_COMMITTEE member initiates a slash, supplying evidence and a victim address.
 *   - A CHALLENGE_PERIOD_SECONDS timelock begins. The agent operator may dispute.
 *   - If undisputed after the challenge period, anyone can call executeSlash.
 *   - On execution: 50% burned, 25% to victim, 25% to the initiating reporter.
 *   - The Identity registry marks the agent Slashed; Reputation zeroes out.
 *
 * Mainnet path: replace SLASHING_COMMITTEE_ROLE with UMA OptimisticOracleV3 or Kleros.
 * The slash initiation/dispute interface is isolated to allow this without touching storage.
 */
contract CountersigStaking is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// 3-of-5 multisig on testnet. Replaced by on-chain arbitration on mainnet.
    bytes32 public constant SLASHING_COMMITTEE_ROLE = keccak256("SLASHING_COMMITTEE_ROLE");

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum SlashState { None, Pending, Executed, Cancelled }

    struct Stake {
        uint256 amount;
        uint256 lockedAt;        // timestamp of the last deposit; recorded for off-chain
                                 // reporting. Retained (not removed) because this struct
                                 // backs the deployed `stakes` mapping — dropping a field
                                 // would shift the slots of unbondingAmount/unbondingAt and
                                 // corrupt every live stake after a UUPS upgrade.
        uint256 unbondingAmount; // queued for withdrawal, still slashable until claimed
        uint256 unbondingAt;     // when unbonding was initiated
    }

    struct SlashProposal {
        bytes32 didHash;
        address reporter;   // initiating committee member
        address victim;     // receives 25% of slashed stake
        uint256 initiatedAt;
        SlashState state;
        bytes evidenceHash; // keccak256 of off-chain evidence blob (stored for auditability)
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    IERC20 public csigToken;
    CountersigIdentity public identityRegistry;
    CountersigReputation public reputationRegistry;

    uint256 public minimumStake;
    uint256 public challengePeriod; // seconds

    mapping(bytes32 => Stake) public stakes;           // didHash => stake
    mapping(bytes32 => SlashProposal) public slashProposals; // didHash => active proposal

    // Appended for the unbonding upgrade. New storage variables must always be
    // declared AFTER all existing ones: inserting above the mappings shifts their
    // base slots, and every live stake/proposal on the already-deployed proxy
    // would become unreachable after a UUPS upgrade.
    // Seconds a withdrawal sits queued (and still slashable) before it can be claimed.
    uint256 public unbondingPeriod;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event StakeDeposited(bytes32 indexed didHash, address indexed operator, uint256 amount);
    event WithdrawalInitiated(bytes32 indexed didHash, address indexed operator, uint256 amount, uint256 claimableAt);
    event WithdrawalClaimed(bytes32 indexed didHash, address indexed operator, uint256 amount);
    event SlashInitiated(bytes32 indexed didHash, address indexed reporter, address indexed victim, uint256 initiatedAt);
    event SlashDisputed(bytes32 indexed didHash, address indexed operator);
    event SlashExecuted(bytes32 indexed didHash, uint256 burned, uint256 toVictim, uint256 toReporter);
    event MinimumStakeUpdated(uint256 newMinimum);
    event ChallengePeriodUpdated(uint256 newPeriod);
    event UnbondingPeriodUpdated(uint256 newPeriod);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InsufficientStake(bytes32 didHash, uint256 provided, uint256 required);
    error NoStake(bytes32 didHash);
    error AgentNotActive(bytes32 didHash);
    error SlashAlreadyPending(bytes32 didHash);
    error NoActivePendingSlash(bytes32 didHash);
    error ChallengePeriodActive(bytes32 didHash, uint256 unlocksAt);
    error ChallengePeriodExpired(bytes32 didHash, uint256 expiredAt);
    error NotOperator(bytes32 didHash, address caller);
    error ZeroAddress();
    error NoWithdrawalPending(bytes32 didHash);
    error WithdrawalAlreadyPending(bytes32 didHash);
    error UnbondingPeriodActive(bytes32 didHash, uint256 claimableAt);

    // -------------------------------------------------------------------------
    // Constructor / Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin              DEFAULT_ADMIN_ROLE + UPGRADER_ROLE.
     * @param identityRegistry_  CountersigIdentity proxy address.
     * @param reputationRegistry_ CountersigReputation proxy address.
     * @param csigToken_         $CSIG ERC20 token address.
     * @param minimumStake_      Minimum $CSIG (in wei) required to register an agent.
     * @param challengePeriod_   Seconds the operator has to dispute a slash (e.g. 7 days = 604800).
     * @param unbondingPeriod_   Seconds a withdrawal sits queued (and still slashable) before it can be claimed.
     */
    function initialize(
        address admin,
        address identityRegistry_,
        address reputationRegistry_,
        address csigToken_,
        uint256 minimumStake_,
        uint256 challengePeriod_,
        uint256 unbondingPeriod_
    ) external initializer {
        if (admin == address(0) || csigToken_ == address(0)) revert ZeroAddress();
        if (identityRegistry_ == address(0) || reputationRegistry_ == address(0)) revert ZeroAddress();

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        identityRegistry = CountersigIdentity(identityRegistry_);
        reputationRegistry = CountersigReputation(reputationRegistry_);
        csigToken = IERC20(csigToken_);
        minimumStake = minimumStake_;
        challengePeriod = challengePeriod_;
        unbondingPeriod = unbondingPeriod_;
    }

    /**
     * @notice Upgrade initializer for proxies deployed before the unbonding feature.
     * @dev    The live proxy already consumed initializer version 1, so the new
     *         initialize() can never run there — without this, unbondingPeriod would
     *         silently stay 0 after the upgrade and withdrawals would be instantly
     *         claimable. Call via upgradeToAndCall so upgrade + config are atomic.
     *         Admin-gated because on FRESH deployments version 2 is still unconsumed
     *         after initialize(), and this must not be callable by a stranger.
     */
    function initializeV2(uint256 unbondingPeriod_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        reinitializer(2)
    {
        unbondingPeriod = unbondingPeriod_;
        emit UnbondingPeriodUpdated(unbondingPeriod_);
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /**
     * @notice Deposit $CSIG to back an agent identity.
     * @dev    Caller must have approved this contract for `amount` before calling.
     *         The agent must already be registered in CountersigIdentity; this call
     *         verifies active status. Additional deposits accumulate on existing stakes.
     */
    function depositStake(bytes32 didHash, uint256 amount) external nonReentrant {
        CountersigIdentity.AgentIdentity memory id = identityRegistry.getIdentity(didHash);
        if (id.registeredAt == 0 || id.status != CountersigIdentity.AgentStatus.Active) {
            revert AgentNotActive(didHash);
        }
        if (id.operator != msg.sender) revert NotOperator(didHash, msg.sender);

        csigToken.safeTransferFrom(msg.sender, address(this), amount);
        stakes[didHash].amount += amount;
        stakes[didHash].lockedAt = block.timestamp;

        emit StakeDeposited(didHash, msg.sender, amount);
    }

    /**
     * @notice Queue a withdrawal. Only permitted if agent is Active and no slash is pending.
     * @dev    Moves `amount` from the active stake into an unbonding queue for
     *         unbondingPeriod seconds. The queued amount is still subject to slashing
     *         during that window (see executeSlash) — queuing a withdrawal does not let
     *         an operator escape accountability for behavior discovered before it clears.
     *         Only one withdrawal may be queued at a time per agent; claim it before
     *         queuing another. Operators must keep the remaining active stake above
     *         minimumStake unless withdrawing to zero (which requires the agent to be
     *         Suspended first via CountersigIdentity.updateStatus).
     */
    function initiateWithdrawal(bytes32 didHash, uint256 amount) external nonReentrant {
        Stake storage s = stakes[didHash];
        if (s.amount == 0) revert NoStake(didHash);
        if (s.unbondingAmount != 0) revert WithdrawalAlreadyPending(didHash);

        CountersigIdentity.AgentIdentity memory id = identityRegistry.getIdentity(didHash);
        if (id.operator != msg.sender) revert NotOperator(didHash, msg.sender);

        if (slashProposals[didHash].state == SlashState.Pending) {
            revert SlashAlreadyPending(didHash);
        }

        uint256 remaining = s.amount - amount;
        // While Active, the remaining active stake must stay at or above minimumStake —
        // withdrawing to zero (fully exiting) requires the operator to Suspend first (see
        // CountersigIdentity.updateStatus). Previously a `remaining != 0` carve-out let an
        // active agent drain its entire backing stake in one step, which the total-balance
        // check in initiateSlash also now guards, but an active agent should never be
        // unbacked to begin with.
        bool active = id.registeredAt != 0 && id.status == CountersigIdentity.AgentStatus.Active;
        if (active && remaining < minimumStake) {
            revert InsufficientStake(didHash, remaining, minimumStake);
        }

        s.amount = remaining;
        s.unbondingAmount = amount;
        s.unbondingAt = block.timestamp;

        emit WithdrawalInitiated(didHash, msg.sender, amount, block.timestamp + unbondingPeriod);
    }

    /**
     * @notice Claim a queued withdrawal once the unbonding period has elapsed.
     * @dev    Reverts if a slash was executed during the window — executeSlash sweeps
     *         and zeroes the unbonding queue along with the active stake, so there is
     *         nothing left to claim.
     */
    function claimWithdrawal(bytes32 didHash) external nonReentrant {
        Stake storage s = stakes[didHash];
        if (s.unbondingAmount == 0) revert NoWithdrawalPending(didHash);

        CountersigIdentity.AgentIdentity memory id = identityRegistry.getIdentity(didHash);
        if (id.operator != msg.sender) revert NotOperator(didHash, msg.sender);

        // A queued withdrawal is still slashable. Without this check, safety would
        // depend on unbondingPeriod staying longer than challengePeriod (both are
        // admin-tunable): if it were ever shorter, an operator could claim mid-slash
        // and dodge the queued portion.
        if (slashProposals[didHash].state == SlashState.Pending) {
            revert SlashAlreadyPending(didHash);
        }

        uint256 claimableAt = s.unbondingAt + unbondingPeriod;
        if (block.timestamp < claimableAt) revert UnbondingPeriodActive(didHash, claimableAt);

        uint256 amount = s.unbondingAmount;
        s.unbondingAmount = 0;
        s.unbondingAt = 0;

        csigToken.safeTransfer(msg.sender, amount);

        emit WithdrawalClaimed(didHash, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Slashing
    // -------------------------------------------------------------------------

    /**
     * @notice Committee member initiates a slash proposal.
     * @dev    Suspends the agent immediately to halt activity during the challenge window.
     *         Evidence hash is the keccak256 of the off-chain evidence package (stored
     *         for auditability; the package itself lives off-chain).
     */
    function initiateSlash(
        bytes32 didHash,
        address victim,
        bytes calldata evidenceHash
    ) external nonReentrant onlyRole(SLASHING_COMMITTEE_ROLE) {
        if (victim == address(0)) revert ZeroAddress();
        // Slashable balance is the active stake PLUS anything queued for withdrawal.
        // Checking only the active stake let an operator drain everything into the
        // unbonding queue (which executeSlash still sweeps) and thereby block the slash
        // from ever being initiated — nullifying accountability. Gate on the total.
        if (stakes[didHash].amount + stakes[didHash].unbondingAmount == 0) revert NoStake(didHash);
        if (slashProposals[didHash].state == SlashState.Pending) revert SlashAlreadyPending(didHash);

        // Write state before the external call (CEI pattern).
        slashProposals[didHash] = SlashProposal({
            didHash: didHash,
            reporter: msg.sender,
            victim: victim,
            initiatedAt: block.timestamp,
            state: SlashState.Pending,
            evidenceHash: evidenceHash
        });

        // Suspend immediately to halt the agent during the dispute window.
        identityRegistry.updateStatus(didHash, CountersigIdentity.AgentStatus.Suspended);

        emit SlashInitiated(didHash, msg.sender, victim, block.timestamp);
    }

    /**
     * @notice Agent operator disputes a pending slash during the challenge period.
     * @dev    Cancels the proposal and reinstates the agent to Active.
     *         The committee may re-initiate with stronger evidence; this does not
     *         permanently block slashing. A governance dispute resolution path is
     *         planned for mainnet.
     */
    function disputeSlash(bytes32 didHash) external nonReentrant {
        SlashProposal storage proposal = slashProposals[didHash];
        if (proposal.state != SlashState.Pending) revert NoActivePendingSlash(didHash);

        uint256 deadline = proposal.initiatedAt + challengePeriod;
        if (block.timestamp > deadline) {
            revert ChallengePeriodExpired(didHash, deadline);
        }

        CountersigIdentity.AgentIdentity memory id = identityRegistry.getIdentity(didHash);
        if (id.operator != msg.sender) revert NotOperator(didHash, msg.sender);

        proposal.state = SlashState.Cancelled;

        // Reinstate the agent.
        identityRegistry.updateStatus(didHash, CountersigIdentity.AgentStatus.Active);

        emit SlashDisputed(didHash, msg.sender);
    }

    /**
     * @notice Execute a slash after the challenge period has elapsed without dispute.
     * @dev    Anyone may call this once the window has closed — execution is permissionless
     *         to avoid committee liveness dependence. The distribution is fixed at init:
     *         50% burned (sent to address(0)), 25% to victim, 25% to reporter.
     */
    function executeSlash(bytes32 didHash) external nonReentrant {
        SlashProposal storage proposal = slashProposals[didHash];
        if (proposal.state != SlashState.Pending) revert NoActivePendingSlash(didHash);

        uint256 deadline = proposal.initiatedAt + challengePeriod;
        if (block.timestamp <= deadline) {
            revert ChallengePeriodActive(didHash, deadline);
        }

        Stake storage s = stakes[didHash];
        // Sweep both the active stake and any queued withdrawal — an unbonding
        // request in flight must not let an operator dodge a slash discovered
        // before the withdrawal actually clears.
        uint256 totalSlashed = s.amount + s.unbondingAmount;
        s.amount = 0;
        s.unbondingAmount = 0;
        s.unbondingAt = 0;

        proposal.state = SlashState.Executed;

        // Distribution: 50% burn, 25% victim, 25% reporter.
        uint256 burned = totalSlashed / 2;
        uint256 toVictim = totalSlashed / 4;
        uint256 toReporter = totalSlashed - burned - toVictim; // absorbs any rounding dust

        // Mark identity as permanently slashed and zero reputation.
        identityRegistry.updateStatus(didHash, CountersigIdentity.AgentStatus.Slashed);
        reputationRegistry.zeroReputation(didHash);

        // Transfer tokens.
        csigToken.safeTransfer(address(0xdead), burned);   // canonical burn address
        csigToken.safeTransfer(proposal.victim, toVictim);
        csigToken.safeTransfer(proposal.reporter, toReporter);

        emit SlashExecuted(didHash, burned, toVictim, toReporter);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setMinimumStake(uint256 newMinimum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumStake = newMinimum;
        emit MinimumStakeUpdated(newMinimum);
    }

    function setChallengePeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        challengePeriod = newPeriod;
        emit ChallengePeriodUpdated(newPeriod);
    }

    function setUnbondingPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unbondingPeriod = newPeriod;
        emit UnbondingPeriodUpdated(newPeriod);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function getStake(bytes32 didHash) external view returns (uint256) {
        return stakes[didHash].amount;
    }

    function hasMinimumStake(bytes32 didHash) external view returns (bool) {
        return stakes[didHash].amount >= minimumStake;
    }

    function getPendingWithdrawal(bytes32 didHash) external view returns (uint256 amount, uint256 claimableAt) {
        Stake storage s = stakes[didHash];
        return (s.unbondingAmount, s.unbondingAmount == 0 ? 0 : s.unbondingAt + unbondingPeriod);
    }

    function getSlashProposal(bytes32 didHash) external view returns (SlashProposal memory) {
        return slashProposals[didHash];
    }

    // -------------------------------------------------------------------------
    // UUPS upgrade authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
