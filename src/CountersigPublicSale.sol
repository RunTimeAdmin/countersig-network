// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title CountersigPublicSale
 * @notice Fixed-price sale of the 15% public allocation (tokenomics v0.3 §2).
 *         Buyers pay a stablecoin at a fixed price for $CSIG.
 *
 *         Terms are IMMUTABLE — set once at construction. There is no owner, no
 *         upgrade path, and every action (buy / finalize / claim / refund) is
 *         permissionless. Buyers get exactly the terms they see.
 *
 *         Soft cap / hard cap with refund:
 *           - Buys accepted during [startTime, endTime], up to hardCap total and
 *             maxPerWallet per address. The contract must hold >= hardCap $CSIG.
 *           - finalize() (after end, or early once hardCap is hit):
 *               * softCap met  -> SUCCESS: stablecoin proceeds go to treasury,
 *                 unsold $CSIG is burned to 0xdead (§2 "unsold ... permanently
 *                 burned, not returned to the treasury"), and buyers claim().
 *               * softCap missed -> FAILURE: buyers refund() their payment, and
 *                 the untouched allocation returns to treasury (a sale that never
 *                 happened does not destroy the allocation).
 *
 *         At TGE the token's `publicSale` recipient is this contract's address,
 *         so the constructor allocation funds the sale directly.
 */
contract CountersigPublicSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable csig;
    IERC20 public immutable paymentToken;
    uint256 public immutable price;        // payment-token units per 1e18 (1 whole) CSIG
    uint64 public immutable startTime;
    uint64 public immutable endTime;
    uint256 public immutable hardCap;      // max CSIG to sell (wei)
    uint256 public immutable softCap;      // min CSIG sold for success (wei)
    uint256 public immutable maxPerWallet; // max CSIG per address (wei)
    address public immutable treasury;

    address internal constant BURN_ADDRESS = address(0xdead);

    uint256 public tokensSold;
    bool public finalized;
    bool public succeeded;

    mapping(address => uint256) public purchased; // CSIG owed to a buyer
    mapping(address => uint256) public paid;       // stablecoin paid by a buyer
    mapping(address => bool) public claimed;
    mapping(address => bool) public refunded;

    event Purchased(address indexed buyer, uint256 tokenAmount, uint256 cost);
    event Finalized(bool succeeded, uint256 tokensSold, uint256 csigMoved);
    event Claimed(address indexed buyer, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);

    error ZeroAddress();
    error BadParams();
    error NotActive();
    error ZeroAmount();
    error SaleNotFunded();
    error HardCapExceeded();
    error WalletCapExceeded();
    error NotEnded();
    error AlreadyFinalized();
    error NotFinalized();
    error NotSucceeded();
    error NotFailed();
    error NothingToClaim();
    error AlreadyClaimed();
    error NothingToRefund();
    error AlreadyRefunded();

    constructor(
        address csig_,
        address paymentToken_,
        uint256 price_,
        uint64 startTime_,
        uint64 endTime_,
        uint256 hardCap_,
        uint256 softCap_,
        uint256 maxPerWallet_,
        address treasury_
    ) {
        if (csig_ == address(0) || paymentToken_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (price_ == 0 || hardCap_ == 0 || maxPerWallet_ == 0) revert BadParams();
        if (startTime_ >= endTime_ || endTime_ <= block.timestamp) revert BadParams();
        if (softCap_ > hardCap_) revert BadParams();

        csig = IERC20(csig_);
        paymentToken = IERC20(paymentToken_);
        price = price_;
        startTime = startTime_;
        endTime = endTime_;
        hardCap = hardCap_;
        softCap = softCap_;
        maxPerWallet = maxPerWallet_;
        treasury = treasury_;
    }

    /// @notice Stablecoin cost of `tokenAmount` CSIG (wei). Rounded up.
    function cost(uint256 tokenAmount) public view returns (uint256) {
        return Math.mulDiv(tokenAmount, price, 1e18, Math.Rounding.Ceil);
    }

    /// @notice True once the contract holds enough $CSIG to honor the full hard cap.
    function isFunded() public view returns (bool) {
        return csig.balanceOf(address(this)) >= hardCap;
    }

    /**
     * @notice Buy `tokenAmount` CSIG (wei) at the fixed price. Caller must approve
     *         the payment token first.
     */
    function buy(uint256 tokenAmount) external nonReentrant {
        if (block.timestamp < startTime || block.timestamp > endTime) revert NotActive();
        if (tokenAmount == 0) revert ZeroAmount();
        if (!isFunded()) revert SaleNotFunded();
        if (tokensSold + tokenAmount > hardCap) revert HardCapExceeded();
        if (purchased[msg.sender] + tokenAmount > maxPerWallet) revert WalletCapExceeded();

        uint256 c = cost(tokenAmount);

        tokensSold += tokenAmount;
        purchased[msg.sender] += tokenAmount;
        paid[msg.sender] += c;

        paymentToken.safeTransferFrom(msg.sender, address(this), c);
        emit Purchased(msg.sender, tokenAmount, c);
    }

    /**
     * @notice Close the sale. Permissionless. Allowed after endTime, or early once
     *         the hard cap is reached.
     */
    function finalize() external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (tokensSold < hardCap && block.timestamp <= endTime) revert NotEnded();

        finalized = true;
        succeeded = tokensSold >= softCap;

        uint256 funded = csig.balanceOf(address(this));

        if (succeeded) {
            // Sold $CSIG stays for claim(); the remainder is unsold -> burned (§2).
            uint256 unsold = funded - tokensSold;
            uint256 raised = paymentToken.balanceOf(address(this));
            if (raised > 0) paymentToken.safeTransfer(treasury, raised);
            if (unsold > 0) csig.safeTransfer(BURN_ADDRESS, unsold);
            emit Finalized(true, tokensSold, unsold);
        } else {
            // No sale happened: buyers refund their stablecoin (kept in the contract),
            // and the whole $CSIG allocation returns to treasury rather than being burned.
            if (funded > 0) csig.safeTransfer(treasury, funded);
            emit Finalized(false, tokensSold, funded);
        }
    }

    /// @notice Claim purchased $CSIG after a successful sale.
    function claim() external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (!succeeded) revert NotSucceeded();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        uint256 amount = purchased[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] = true;
        csig.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Refund stablecoin after a failed sale.
    function refund() external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (succeeded) revert NotFailed();
        if (refunded[msg.sender]) revert AlreadyRefunded();

        uint256 amount = paid[msg.sender];
        if (amount == 0) revert NothingToRefund();

        refunded[msg.sender] = true;
        paymentToken.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }
}
