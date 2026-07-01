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
 * is a verified store: it accepts oracle-proposed score updates and exposes them
 * to on-chain consumers (e.g., agent-to-agent trust checks).
 *
 * Score factors and weights (total: 100):
 *   feeScore        — max 30 — on-chain fee/transaction volume
 *   successScore    — max 25 — attestation-confirmed task completions
 *   ageScore        — max 20 — logarithmic age: min(20, floor(log2(days+1) * 4))
 *   externalScore   — max 15 — SAID Protocol / Gitcoin Passport cross-platform score
 *   communityScore  — max  5 — flag-free community standing
 *   propagationScore — max 5 — inherited trust from high-reputation vouchers
 *
 * Optimistic scoring model:
 *   - The oracle proposes a score via proposeReputation(). A challenge window opens.
 *   - If unchallenged, anyone may call finalizeReputation() once the window elapses.
 *   - During the window, SLASHING_COMMITTEE_ROLE may reject a bad proposal outright —
 *     the committee's challenge is itself the ruling, mirroring how slash disputes
 *     already work in CountersigStaking, rather than introducing a separate
 *     propose-then-arbitrate step.
 *   - A fresh proposal for the same agent replaces any still-pending one and restarts
 *     the window; the previous pending proposal is simply abandoned.
 */
contract CountersigReputation is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// Granted to the oracle consensus contract(s) authorized to propose scores.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// Granted to the StakingCore so it can zero scores on slash.
    bytes32 public constant STAKING_CORE_ROLE = keccak256("STAKING_CORE_ROLE");

    /// Same committee that resolves slash disputes in CountersigStaking — granted
    /// here separately since each contract keeps its own independent role registry.
    bytes32 public constant SLASHING_COMMITTEE_ROLE = keccak256("SLASHING_COMMITTEE_ROLE");

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
        uint256 lastUpdated;     // block.timestamp of last finalized write
    }

    struct PendingScore {
        ReputationData data;
        uint256 proposedAt;
        bool exists;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(bytes32 => ReputationData) public reputations;
    mapping(bytes32 => PendingScore) public pendingScores;

    /// Seconds a proposed score sits open to challenge before it can be finalized.
    uint256 public challengeWindow;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ScoreProposed(bytes32 indexed didHash, uint256 proposedAt);
    event ReputationUpdated(bytes32 indexed didHash, uint8 totalScore, uint256 timestamp);
    event ScoreRejected(bytes32 indexed didHash, address indexed committee);
    event ReputationZeroed(bytes32 indexed didHash);
    event ChallengeWindowUpdated(uint256 newWindow);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ScoreOutOfRange(string factor, uint8 value, uint8 max);
    error NoScorePending(bytes32 didHash);
    error ChallengeWindowActive(bytes32 didHash, uint256 finalizableAt);
    error ChallengeWindowExpired(bytes32 didHash, uint256 expiredAt);

    // -------------------------------------------------------------------------
    // Constructor / Initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin           DEFAULT_ADMIN_ROLE + UPGRADER_ROLE. Governance timelock on mainnet.
     * @param oracle          Initial oracle address granted ORACLE_ROLE. Additional oracles
     *                        can be granted via DEFAULT_ADMIN.
     * @param stakingCore     Granted STAKING_CORE_ROLE to zero scores on slash.
     * @param slashingCommittee Granted SLASHING_COMMITTEE_ROLE to reject bad proposals.
     * @param challengeWindow_ Seconds a proposed score can be challenged before finalizing
     *                        (e.g. 3600 = 1 hour, 21600 = 6 hours).
     */
    function initialize(
        address admin,
        address oracle,
        address stakingCore,
        address slashingCommittee,
        uint256 challengeWindow_
    ) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        if (oracle != address(0)) _grantRole(ORACLE_ROLE, oracle);
        if (stakingCore != address(0)) _grantRole(STAKING_CORE_ROLE, stakingCore);
        if (slashingCommittee != address(0)) _grantRole(SLASHING_COMMITTEE_ROLE, slashingCommittee);

        challengeWindow = challengeWindow_;
    }

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /**
     * @notice Oracle proposes a score update for an agent. Opens a challenge window.
     * @dev    Validates each factor against its cap before accepting. Replaces any
     *         still-pending proposal for the same agent and restarts the window —
     *         the newer proposal reflects fresher on-chain state.
     */
    function proposeReputation(bytes32 didHash, ReputationData calldata data)
        external
        onlyRole(ORACLE_ROLE)
    {
        if (data.feeScore > MAX_FEE_SCORE)               revert ScoreOutOfRange("feeScore", data.feeScore, MAX_FEE_SCORE);
        if (data.successScore > MAX_SUCCESS_SCORE)        revert ScoreOutOfRange("successScore", data.successScore, MAX_SUCCESS_SCORE);
        if (data.ageScore > MAX_AGE_SCORE)                revert ScoreOutOfRange("ageScore", data.ageScore, MAX_AGE_SCORE);
        if (data.externalScore > MAX_EXTERNAL_SCORE)      revert ScoreOutOfRange("externalScore", data.externalScore, MAX_EXTERNAL_SCORE);
        if (data.communityScore > MAX_COMMUNITY_SCORE)    revert ScoreOutOfRange("communityScore", data.communityScore, MAX_COMMUNITY_SCORE);
        if (data.propagationScore > MAX_PROPAGATION_SCORE) revert ScoreOutOfRange("propagationScore", data.propagationScore, MAX_PROPAGATION_SCORE);

        pendingScores[didHash] = PendingScore({
            data: data,
            proposedAt: block.timestamp,
            exists: true
        });

        emit ScoreProposed(didHash, block.timestamp);
    }

    /**
     * @notice Finalize a proposed score once its challenge window has elapsed unrejected.
     * @dev    Permissionless — execution doesn't depend on any single party's liveness.
     */
    function finalizeReputation(bytes32 didHash) external {
        PendingScore storage pending = pendingScores[didHash];
        if (!pending.exists) revert NoScorePending(didHash);

        uint256 finalizableAt = pending.proposedAt + challengeWindow;
        if (block.timestamp < finalizableAt) revert ChallengeWindowActive(didHash, finalizableAt);

        reputations[didHash] = pending.data;
        reputations[didHash].lastUpdated = block.timestamp;
        delete pendingScores[didHash];

        emit ReputationUpdated(didHash, getTotalScore(didHash), block.timestamp);
    }

    /**
     * @notice Committee rejects a pending proposal during its challenge window.
     * @dev    The committee's rejection is itself the ruling — no separate dispute
     *         resolution step, mirroring how slash initiation works in CountersigStaking.
     *         The agent's existing finalized score is untouched; only the pending
     *         proposal is discarded.
     */
    function rejectReputation(bytes32 didHash) external onlyRole(SLASHING_COMMITTEE_ROLE) {
        PendingScore storage pending = pendingScores[didHash];
        if (!pending.exists) revert NoScorePending(didHash);

        uint256 finalizableAt = pending.proposedAt + challengeWindow;
        if (block.timestamp >= finalizableAt) revert ChallengeWindowExpired(didHash, finalizableAt);

        delete pendingScores[didHash];

        emit ScoreRejected(didHash, msg.sender);
    }

    /**
     * @notice Zero out an agent's score after a slash. Called by StakingCore.
     * @dev    Sets all scores to 0 but preserves lastUpdated so history is not lost.
     *         Also clears any pending proposal — a slashed agent's score is terminal.
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
        delete pendingScores[didHash];

        emit ReputationZeroed(didHash);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setChallengeWindow(uint256 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        challengeWindow = newWindow;
        emit ChallengeWindowUpdated(newWindow);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function getReputation(bytes32 didHash) external view returns (ReputationData memory) {
        return reputations[didHash];
    }

    function getPendingScore(bytes32 didHash) external view returns (PendingScore memory) {
        return pendingScores[didHash];
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
        // Each factor is validated at propose time, so total <= 100.
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
