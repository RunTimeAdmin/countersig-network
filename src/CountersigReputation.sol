// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title CountersigReputation
 * @notice Stores the 6-factor reputation score for each registered agent.
 *
 * All scoring computation happens off-chain in the oracle network. This contract
 * is a verified store: it accepts oracle-signed score updates and exposes them
 * to on-chain consumers (e.g., agent-to-agent trust checks).
 *
 * Score factors and weights (total: 100):
 *   feeScore        — max 30 — on-chain fee/transaction volume
 *   successScore    — max 25 — attestation-confirmed task completions
 *   ageScore        — max 20 — logarithmic age: min(20, floor(log2(days+1) * 4))
 *   externalScore   — max 15 — SAID Protocol / Gitcoin Passport cross-platform score
 *   communityScore  — max  5 — flag-free community standing
 *   propagationScore — max 5 — inherited trust from high-reputation vouchers
 */
contract CountersigReputation is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// Granted to the oracle consensus contract(s) authorized to write scores.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// Granted to the StakingCore so it can zero scores on slash.
    bytes32 public constant STAKING_CORE_ROLE = keccak256("STAKING_CORE_ROLE");

    /// Granted to admin/governance timelock for upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // -------------------------------------------------------------------------
    // Score caps (sum to 100)
    // -------------------------------------------------------------------------

    uint8 public constant MAX_FEE_SCORE = 30;
    uint8 public constant MAX_SUCCESS_SCORE = 25;
    uint8 public constant MAX_AGE_SCORE = 20;
    uint8 public constant MAX_EXTERNAL_SCORE = 15;
    uint8 public constant MAX_COMMUNITY_SCORE = 5;
    uint8 public constant MAX_PROPAGATION_SCORE = 5;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct ReputationData {
        uint8 feeScore;          // max 30
        uint8 successScore;      // max 25
        uint8 ageScore;          // max 20
        uint8 externalScore;     // max 15
        uint8 communityScore;    // max  5
        uint8 propagationScore;  // max  5
        uint256 lastUpdated;     // block.timestamp of last oracle write
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(bytes32 => ReputationData) public reputations;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ReputationUpdated(bytes32 indexed didHash, uint8 totalScore, uint256 timestamp);
    event ReputationZeroed(bytes32 indexed didHash);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ScoreOutOfRange(string factor, uint8 value, uint8 max);

    // -------------------------------------------------------------------------
    // Constructor / Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin       DEFAULT_ADMIN_ROLE + UPGRADER_ROLE. Governance timelock on mainnet.
     * @param oracle      Initial oracle address granted ORACLE_ROLE. Additional oracles
     *                    can be granted via DEFAULT_ADMIN.
     * @param stakingCore Granted STAKING_CORE_ROLE to zero scores on slash.
     */
    function initialize(address admin, address oracle, address stakingCore) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        if (oracle != address(0)) _grantRole(ORACLE_ROLE, oracle);
        if (stakingCore != address(0)) _grantRole(STAKING_CORE_ROLE, stakingCore);
    }

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /**
     * @notice Oracle writes a full score update for an agent.
     * @dev    Validates each factor against its cap before writing. The oracle is
     *         responsible for computing correct values; this is a sanity guard only.
     *         Agents do not need to be registered in CountersigIdentity for a score
     *         to be written — but in practice the oracle only scores registered agents.
     */
    function updateReputation(bytes32 didHash, ReputationData calldata data)
        external
        onlyRole(ORACLE_ROLE)
    {
        if (data.feeScore > MAX_FEE_SCORE)               revert ScoreOutOfRange("feeScore", data.feeScore, MAX_FEE_SCORE);
        if (data.successScore > MAX_SUCCESS_SCORE)        revert ScoreOutOfRange("successScore", data.successScore, MAX_SUCCESS_SCORE);
        if (data.ageScore > MAX_AGE_SCORE)                revert ScoreOutOfRange("ageScore", data.ageScore, MAX_AGE_SCORE);
        if (data.externalScore > MAX_EXTERNAL_SCORE)      revert ScoreOutOfRange("externalScore", data.externalScore, MAX_EXTERNAL_SCORE);
        if (data.communityScore > MAX_COMMUNITY_SCORE)    revert ScoreOutOfRange("communityScore", data.communityScore, MAX_COMMUNITY_SCORE);
        if (data.propagationScore > MAX_PROPAGATION_SCORE) revert ScoreOutOfRange("propagationScore", data.propagationScore, MAX_PROPAGATION_SCORE);

        reputations[didHash] = ReputationData({
            feeScore: data.feeScore,
            successScore: data.successScore,
            ageScore: data.ageScore,
            externalScore: data.externalScore,
            communityScore: data.communityScore,
            propagationScore: data.propagationScore,
            lastUpdated: block.timestamp
        });

        emit ReputationUpdated(didHash, getTotalScore(didHash), block.timestamp);
    }

    /**
     * @notice Zero out an agent's score after a slash. Called by StakingCore.
     * @dev    Sets all scores to 0 but preserves lastUpdated so history is not lost.
     */
    function zeroReputation(bytes32 didHash) external onlyRole(STAKING_CORE_ROLE) {
        reputations[didHash] = ReputationData({
            feeScore: 0,
            successScore: 0,
            ageScore: 0,
            externalScore: 0,
            communityScore: 0,
            propagationScore: 0,
            lastUpdated: block.timestamp
        });

        emit ReputationZeroed(didHash);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function getReputation(bytes32 didHash) external view returns (ReputationData memory) {
        return reputations[didHash];
    }

    /// @notice Returns the sum of all 6 factor scores. Max 100.
    function getTotalScore(bytes32 didHash) public view returns (uint8) {
        ReputationData storage rep = reputations[didHash];
        uint16 total = uint16(rep.feeScore)
            + uint16(rep.successScore)
            + uint16(rep.ageScore)
            + uint16(rep.externalScore)
            + uint16(rep.communityScore)
            + uint16(rep.propagationScore);
        // Each factor is validated at write time (updateReputation), so total <= 100.
        assert(total <= 100);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(total);
    }

    function meetsThreshold(bytes32 didHash, uint8 threshold) external view returns (bool) {
        return getTotalScore(didHash) >= threshold;
    }

    // -------------------------------------------------------------------------
    // UUPS upgrade authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
