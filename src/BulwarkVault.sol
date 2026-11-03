// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20, IStabilityPool, ISortedTroves} from "./interfaces/IMezo.sol";

/// @title BulwarkVault (v2)
/// @notice One vault per user. The vault is the borrower of record for a Mezo MUSD loan
///         and holds an MUSD reserve. When the loan's collateral ratio falls below the
///         owner's trigger, anyone (a keeper) can call `rescue`, which repays debt from the
///         reserve until the ratio is back at the owner's target, and pays the keeper a fee.
///
///         v2: the reserve can earn. While `earning` is on, reserve MUSD sits in Mezo's
///         Stability Pool, where it earns BTC from liquidations. A rescue pulls what it needs
///         back out in the same transaction. `harvest` (anyone can call it) moves the BTC the
///         reserve earned into the loan as extra collateral, so the earnings make the loan safer.
///
///         The pool refuses withdrawals while any Mezo loan sits below 110%, which can happen in
///         the same crash that needs a rescue. So a share of the reserve (`liquidBps`, 25% by
///         default) always stays on hand, and keepers can liquidate the under-water loans that
///         block the pool before they rescue.
contract BulwarkVault {
    uint256 internal constant ONE = 1e18;
    uint256 public constant MAX_FEE_BPS = 200; // 2% hard cap on keeper fees
    uint256 public constant MIN_TRIGGER = 1.15e18; // must sit above Mezo's 110% liquidation line
    uint256 internal constant DEBT_MARGIN = 1e18; // stay 1 MUSD above Mezo's minimum debt
    uint256 internal constant MCR = 1.1e18; // Mezo's liquidation line
    uint256 public constant VERSION = 2;

    IBorrowerOperations public immutable borrowerOps;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IERC20 public immutable musd;
    IStabilityPool public immutable stabilityPool;
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
    /// When on, reserve MUSD is kept in the Stability Pool so it earns.
    bool public earning = true;
    /// Share of the reserve kept on hand, outside the pool (10,000 = 100%).
    uint16 public liquidBps = 2_500;
    /// BTC the reserve has earned and moved into the loan so far.
    uint256 public totalHarvested;
    bool private locked;

    event LoanOpened(uint256 collateral, uint256 borrowed, uint256 keptAsReserve);
    event RuleSet(uint256 triggerICR, uint256 targetICR, uint256 feeBps);
    event ReserveDeposited(address indexed from, uint256 amount);
    event ReserveWithdrawn(uint256 amount);
    event CollateralAdded(address indexed from, uint256 amount);
    event Rescued(address indexed keeper, uint256 icrBefore, uint256 icrAfter, uint256 repaid, uint256 fee, uint256 price);
    event LoanClosed(uint256 collateralReturned);
    event EarningSet(bool on, uint256 liquidBps);
    event Staked(uint256 amount);
    event Unstaked(uint256 amount);
    event Harvested(address indexed by, uint256 btc);

    error NotOwner();
    error BadRule();
    error Healthy(uint256 icr, uint256 trigger);
    error NoRule();
    error NothingToRepay();
    error NoImprovement();
    error TransferFailed();
    error Reentrancy();
    error NothingToHarvest();

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

    constructor(
        address _owner,
        address _borrowerOps,
        address _troveManager,
        address _priceFeed,
        address _musd,
        address _stabilityPool
    ) {
        owner = _owner;
        factory = msg.sender;
        borrowerOps = IBorrowerOperations(_borrowerOps);
        troveManager = ITroveManager(_troveManager);
        priceFeed = IPriceFeed(_priceFeed);
        musd = IERC20(_musd);
        stabilityPool = IStabilityPool(_stabilityPool);
        // The Stability Pool pulls deposits with transferFrom.
        IERC20(_musd).approve(_stabilityPool, type(uint256).max);
    }

    // ---------------------------------------------------------------- owner: loan

    /// Opens the loan with the BTC sent. `keepAsReserve` of the borrowed MUSD stays in the
    /// vault as the rescue reserve (and starts earning); the rest goes to the owner.
    function openLoan(uint256 borrowAmount, uint256 keepAsReserve, address upperHint, address lowerHint)
        external
        payable
        onlyOwner
        nonReentrant
    {
        require(keepAsReserve <= borrowAmount, "reserve > borrow");
        borrowerOps.openTrove{value: msg.value}(borrowAmount, upperHint, lowerHint);
        _sendMUSD(owner, borrowAmount - keepAsReserve);
        _rebalance();
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
        _ensureLiquid(amount);
        borrowerOps.repayMUSD(amount, upperHint, lowerHint);
    }

    /// Closes the loan. The vault must hold enough MUSD (reserve plus any deposit) to clear
    /// the debt; Mezo refunds its 200 MUSD gas deposit. BTC and leftover MUSD go to the owner.
    function closeLoan() external onlyOwner nonReentrant {
        _unstakeAll();
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
        _ensureLiquid(amount);
        _sendMUSD(owner, amount);
        emit ReserveWithdrawn(amount);
    }

    // ---------------------------------------------------------------- owner: earning

    /// Turns earning on or off and sets how much of the reserve stays on hand (10,000 = all of it).
    /// Off pulls the whole reserve back out of the pool.
    function setEarning(bool on, uint256 _liquidBps) external onlyOwner nonReentrant {
        require(_liquidBps <= 10_000, "liquidBps > 100%");
        earning = on;
        liquidBps = uint16(_liquidBps);
        if (on) _rebalance();
        else _unstakeAll();
        emit EarningSet(on, _liquidBps);
    }

    // ---------------------------------------------------------------- anyone

    /// Adds MUSD to the reserve. Needs an approval first.
    function depositReserve(uint256 amount) external nonReentrant {
        if (!musd.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        _rebalance();
        emit ReserveDeposited(msg.sender, amount);
    }

    /// Adds the BTC sent as extra collateral.
    function addCollateral(address upperHint, address lowerHint) external payable nonReentrant {
        borrowerOps.addColl{value: msg.value}(upperHint, lowerHint);
        emit CollateralAdded(msg.sender, msg.value);
    }

    /// Brings the on-hand share back to `liquidBps` (for example after a rescue spent it).
    /// Anyone can call it; it does nothing while the pool is locked.
    function rebalance() external nonReentrant {
        _rebalance();
    }

    /// Moves the BTC the reserve earned into the loan as extra collateral. Anyone can call it.
    function harvest(address upperHint, address lowerHint) external nonReentrant returns (uint256 btc) {
        if (troveManager.getTroveStatus(address(this)) != 1) revert NothingToHarvest();
        // BTC still waiting in the pool goes straight into the loan.
        uint256 gain = stabilityPool.getDepositorCollateralGain(address(this));
        if (gain > 0) {
            stabilityPool.withdrawCollateralGainToTrove(upperHint, lowerHint);
            btc += gain;
        }
        // BTC the pool already paid out to the vault (it does on every deposit or withdrawal).
        uint256 loose = address(this).balance;
        if (loose > 0) {
            borrowerOps.addColl{value: loose}(upperHint, lowerHint);
            btc += loose;
        }
        if (btc == 0) revert NothingToHarvest();
        totalHarvested += btc;
        emit Harvested(msg.sender, btc);
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

        // Pull what's needed out of the Stability Pool. If the pool refuses (it blocks
        // withdrawals while any Mezo loan sits below 110%), rescue with what's on hand.
        uint256 liquid = musd.balanceOf(address(this));
        if (liquid < repaid + fee) {
            _tryUnstake(repaid + fee - liquid);
            liquid = musd.balanceOf(address(this));
            if (liquid < repaid + fee) {
                repaid = (liquid * 10_000) / (10_000 + r.feeBps);
                fee = (repaid * r.feeBps) / 10_000;
                if (repaid == 0) revert NothingToRepay();
            }
        }

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

    /// True while the Stability Pool refuses withdrawals (some Mezo loan sits below 110%).
    /// Keepers can unlock it by liquidating those loans. Call with eth_call.
    function poolLocked() external returns (bool) {
        return _poolLocked(priceFeed.fetchPrice());
    }

    /// The whole reserve: MUSD on hand plus MUSD in the Stability Pool.
    function reserve() public view returns (uint256) {
        return musd.balanceOf(address(this)) + reserveEarning();
    }

    /// Reserve MUSD sitting in the vault, ready to spend.
    function reserveLiquid() external view returns (uint256) {
        return musd.balanceOf(address(this));
    }

    /// Reserve MUSD in the Stability Pool.
    function reserveEarning() public view returns (uint256) {
        return stabilityPool.getCompoundedMUSDDeposit(address(this));
    }

    /// BTC the reserve has earned that `harvest` can move into the loan.
    function pendingHarvest() external view returns (uint256) {
        return stabilityPool.getDepositorCollateralGain(address(this)) + address(this).balance;
    }

    /// Where this loan sits in Mezo's redemption line. Redemptions take BTC from the loans with
    /// the lowest collateral ratio first, so `debtAhead` is how much MUSD would have to be
    /// redeemed from other loans before this one is touched. `rank` 1 means first in line.
    /// Walks the sorted list from the riskiest end; meant for eth_call (dashboards, keepers).
    function redemptionPosition() external view returns (uint256 rank, uint256 debtAhead, uint256 totalLoans) {
        ISortedTroves sorted = ISortedTroves(stabilityPool.sortedTroves());
        uint256 gasComp = borrowerOps.MUSD_GAS_COMPENSATION(); // never redeemable
        totalLoans = sorted.getSize();
        address cur = sorted.getLast();
        while (cur != address(0) && cur != address(this)) {
            (, uint256 p, uint256 i,,,) = troveManager.getEntireDebtAndColl(cur);
            uint256 d = p + i;
            debtAhead += d > gasComp ? d - gasComp : 0;
            rank += 1;
            cur = sorted.getPrev(cur);
        }
        if (cur == address(0)) return (0, debtAhead, totalLoans); // no open loan
        rank += 1;
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

        // Repay plus fee must fit in the reserve we can actually reach right now.
        uint256 res = _poolLocked(price) ? musd.balanceOf(address(this)) : reserve();
        uint256 maxByReserve = (res * 10_000) / (10_000 + r.feeBps);
        if (repay > maxByReserve) repay = maxByReserve;

        fee = (repay * r.feeBps) / 10_000;
    }

    function _poolLocked(uint256 price) internal view returns (bool) {
        if (stabilityPool.deposits(address(this)) == 0) return false;
        address lowest = ISortedTroves(stabilityPool.sortedTroves()).getLast();
        return lowest != address(0) && troveManager.getCurrentICR(lowest, price) < MCR;
    }

    /// Keeps `liquidBps` of the reserve on hand and the rest in the pool.
    function _rebalance() internal {
        if (!earning) return;
        uint256 liquid = musd.balanceOf(address(this));
        uint256 want = (reserve() * liquidBps) / 10_000;
        if (liquid > want) {
            uint256 amount = liquid - want;
            stabilityPool.provideToSP(amount);
            emit Staked(amount);
        } else if (want > liquid + 1e15) {
            _tryUnstake(want - liquid);
        }
    }

    /// Makes sure `amount` MUSD is on hand, pulling the shortfall from the pool (reverts if it can't).
    function _ensureLiquid(uint256 amount) internal {
        uint256 liquid = musd.balanceOf(address(this));
        if (liquid >= amount || stabilityPool.deposits(address(this)) == 0) return;
        uint256 need = amount - liquid;
        stabilityPool.withdrawFromSP(need);
        emit Unstaked(need);
    }

    function _unstakeAll() internal {
        if (stabilityPool.deposits(address(this)) == 0) return;
        uint256 amount = stabilityPool.getCompoundedMUSDDeposit(address(this));
        stabilityPool.withdrawFromSP(amount);
        emit Unstaked(amount);
    }

    function _tryUnstake(uint256 amount) internal {
        if (stabilityPool.deposits(address(this)) == 0) return;
        try stabilityPool.withdrawFromSP(amount) {
            emit Unstaked(amount);
        } catch {}
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
