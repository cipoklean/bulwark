// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20} from "./interfaces/IMezo.sol";

/// @title BulwarkVault
/// @notice One vault per user. The vault is the borrower of record for a Mezo MUSD loan
///         and holds an MUSD reserve. When the loan's collateral ratio falls below the
///         owner's trigger, anyone (a keeper) can call `rescue`, which repays debt from the
///         reserve until the ratio is back at the owner's target, and pays the keeper a fee.
contract BulwarkVault {
    uint256 internal constant ONE = 1e18;
    uint256 public constant MAX_FEE_BPS = 200; // 2% hard cap on keeper fees
    uint256 public constant MIN_TRIGGER = 1.15e18; // must sit above Mezo's 110% liquidation line
    uint256 internal constant DEBT_MARGIN = 1e18; // stay 1 MUSD above Mezo's minimum debt

    IBorrowerOperations public immutable borrowerOps;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IERC20 public immutable musd;
    address public immutable owner;
    address public immutable factory;

    struct Rule {
        uint64 triggerICR; // rescue allowed below this ratio (1e18 = 100%)
        uint64 targetICR; // rescue repays until the ratio reaches this
        uint16 feeBps; // keeper fee, as a share of the MUSD repaid
    }

    Rule public rule;
    uint256 public rescueCount;
    uint256 public totalRepaidByRescues;
    bool private locked;

    event LoanOpened(uint256 collateral, uint256 borrowed, uint256 keptAsReserve);
    event RuleSet(uint256 triggerICR, uint256 targetICR, uint256 feeBps);
    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(uint256 amount);
    event CollateralAdded(address indexed from, uint256 amount);
    event Rescued(address indexed keeper, uint256 icrBefore, uint256 icrAfter, uint256 repaid, uint256 fee, uint256 price);
    event LoanClosed(uint256 collateralReturned);

    error NotOwner();
    error BadRule();
    error Healthy(uint256 icr, uint256 trigger);
    error NoRule();
    error NothingToRepay();
    error NoImprovement();
    error TransferFailed();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _owner, address _borrowerOps, address _troveManager, address _priceFeed, address _musd) {
        owner = _owner;
        factory = msg.sender;
        borrowerOps = IBorrowerOperations(_borrowerOps);
        troveManager = ITroveManager(_troveManager);
        priceFeed = IPriceFeed(_priceFeed);
        musd = IERC20(_musd);
    }

    // ---------------------------------------------------------------- owner: loan

    /// Opens the loan with the BTC sent. `keepAsReserve` of the borrowed MUSD stays in the
    /// vault as the rescue reserve; the rest goes to the owner.
    function openLoan(uint256 borrowAmount, uint256 keepAsReserve, address upperHint, address lowerHint)
        external
        payable
        onlyOwner
        nonReentrant
    {
        require(keepAsReserve <= borrowAmount, "reserve > borrow");
        borrowerOps.openTrove{value: msg.value}(borrowAmount, upperHint, lowerHint);
        _sendMUSD(owner, borrowAmount - keepAsReserve);
        emit LoanOpened(msg.value, borrowAmount, keepAsReserve);
    }

    function setRule(uint256 triggerICR, uint256 targetICR, uint256 feeBps) external onlyOwner {
        if (triggerICR < MIN_TRIGGER || targetICR <= triggerICR || targetICR > 10e18 || feeBps > MAX_FEE_BPS) {
            revert BadRule();
        }
        rule = Rule(uint64(triggerICR), uint64(targetICR), uint16(feeBps));
        emit RuleSet(triggerICR, targetICR, feeBps);
    }

    function borrowMore(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        borrowerOps.withdrawMUSD(amount, upperHint, lowerHint);
        _sendMUSD(owner, amount);
    }

    function withdrawCollateral(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        borrowerOps.withdrawColl(amount, upperHint, lowerHint);
        _sendBTC(owner, amount);
    }

    /// Owner repays from the reserve by hand (no fee).
    function repayFromReserve(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        borrowerOps.repayMUSD(amount, upperHint, lowerHint);
    }

    /// Closes the loan. The vault must hold enough MUSD (reserve plus any deposit) to clear
    /// the debt; Mezo refunds its 200 MUSD gas deposit. BTC and leftover MUSD go to the owner.
    function closeLoan() external onlyOwner nonReentrant {
        uint256 before = address(this).balance;
        borrowerOps.closeTrove();
        uint256 returned = address(this).balance - before;
        _sendBTC(owner, address(this).balance);
        _sendMUSD(owner, musd.balanceOf(address(this)));
        emit LoanClosed(returned);
    }

    /// Claims BTC left over for this vault after a liquidation or redemption.
    function claimCollateral() external onlyOwner nonReentrant {
        borrowerOps.claimCollateral();
        _sendBTC(owner, address(this).balance);
    }

    function withdrawReserve(uint256 amount) external onlyOwner nonReentrant {
        _sendMUSD(owner, amount);
        emit ReserveWithdrawn(amount);
    }

    // ---------------------------------------------------------------- anyone

    /// Adds MUSD to the reserve. Needs an approval first.
    function depositReserve(uint256 amount) external nonReentrant {
        if (!musd.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit ReserveDeposited(msg.sender, amount);
    }

    /// Adds the BTC sent as extra collateral.
    function addCollateral(address upperHint, address lowerHint) external payable nonReentrant {
        borrowerOps.addColl{value: msg.value}(upperHint, lowerHint);
        emit CollateralAdded(msg.sender, msg.value);
    }

    /// Permissionless rescue. Works only while the ratio is below the owner's trigger.
    /// Repays from the reserve toward the target ratio and pays the caller the fee.
    /// Hints are optional (address(0) works but costs more gas); keepers compute them off-chain.
    function rescue(address upperHint, address lowerHint) external nonReentrant returns (uint256 repaid, uint256 fee) {
        Rule memory r = rule;
        if (r.targetICR == 0) revert NoRule();

        uint256 price = priceFeed.fetchPrice();
        uint256 icrBefore = troveManager.getCurrentICR(address(this), price);
        if (icrBefore >= r.triggerICR) revert Healthy(icrBefore, r.triggerICR);

        (repaid, fee) = _rescueAmounts(price, r);
        if (repaid == 0) revert NothingToRepay();

        borrowerOps.repayMUSD(repaid, upperHint, lowerHint);
        uint256 icrAfter = troveManager.getCurrentICR(address(this), price);
        if (icrAfter <= icrBefore) revert NoImprovement();

        rescueCount += 1;
        totalRepaidByRescues += repaid;
        _sendMUSD(msg.sender, fee);
        emit Rescued(msg.sender, icrBefore, icrAfter, repaid, fee, price);
    }

    // ---------------------------------------------------------------- views

    /// What a rescue would do right now. Keepers call this with eth_call.
    function previewRescue() external returns (bool canRescue, uint256 icr, uint256 repay, uint256 fee) {
        Rule memory r = rule;
        uint256 price = priceFeed.fetchPrice();
        icr = troveManager.getCurrentICR(address(this), price);
        if (r.targetICR == 0 || icr >= r.triggerICR || troveManager.getTroveStatus(address(this)) != 1) {
            return (false, icr, 0, 0);
        }
        (repay, fee) = _rescueAmounts(price, r);
        canRescue = repay > 0;
    }

    function reserve() public view returns (uint256) {
        return musd.balanceOf(address(this));
    }

    function loan() public view returns (uint256 coll, uint256 debt) {
        (uint256 c, uint256 p, uint256 i,,,) = troveManager.getEntireDebtAndColl(address(this));
        return (c, p + i);
    }

    // ---------------------------------------------------------------- internals

    function _rescueAmounts(uint256 price, Rule memory r) internal view returns (uint256 repay, uint256 fee) {
        (uint256 coll, uint256 debt) = loan();
        // Debt at which the ratio equals the target: coll * price / target.
        uint256 targetDebt = (coll * price) / r.targetICR;
        if (targetDebt >= debt) return (0, 0);
        repay = debt - targetDebt;

        // Mezo rejects a repayment that takes net debt below its minimum.
        uint256 floor = borrowerOps.minNetDebt() + borrowerOps.MUSD_GAS_COMPENSATION() + DEBT_MARGIN;
        uint256 maxByFloor = debt > floor ? debt - floor : 0;
        if (repay > maxByFloor) repay = maxByFloor;

        // Repay plus fee must fit in the reserve.
        uint256 res = reserve();
        uint256 maxByReserve = (res * 10_000) / (10_000 + r.feeBps);
        if (repay > maxByReserve) repay = maxByReserve;

        fee = (repay * r.feeBps) / 10_000;
    }

    function _sendMUSD(address to, uint256 amount) internal {
        if (amount > 0 && !musd.transfer(to, amount)) revert TransferFailed();
    }

    function _sendBTC(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
