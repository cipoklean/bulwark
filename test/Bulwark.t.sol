// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BulwarkFactory} from "../src/BulwarkFactory.sol";
import {BulwarkVault} from "../src/BulwarkVault.sol";
import {ITroveManager, IERC20, IStabilityPool} from "../src/interfaces/IMezo.sol";

interface ILiquidate {
    function liquidate(address borrower) external;
}

interface ISorted {
    function getLast() external view returns (address);
    function getPrev(address) external view returns (address);
}

interface IBatch {
    function batchLiquidateTroves(address[] calldata borrowers) external;
}

interface IOpen {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;
}

/// Stand-in for Mezo's oracle precompile, which a local fork cannot run.
contract MockOracle2 {
    int256 public answer;
    function set(int256 a) external { answer = a; }
    function decimals() external pure returns (uint8) { return 18; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract BulwarkTest is Test {
    address constant ORACLE = 0x7b7c000000000000000000000000000000000015;
    address constant BO = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TM = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant PF = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant SP = 0x1CCA7E410eE41739792eA0A24e00349Dd247680e;
    address constant ST = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;

    BulwarkFactory factory;
    BulwarkVault vault;
    // Fresh addresses, so balances left on testnet by other people can't skew the checks.
    address alice = makeAddr("bulwark-alice");
    address keeper = makeAddr("bulwark-keeper");

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC", string("https://rpc.test.mezo.org")));
        vm.etch(ORACLE, address(new MockOracle2()).code);
        MockOracle2(ORACLE).set(80_000e18);
        factory = new BulwarkFactory(BO, TM, PF, MUSD, SP);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vault = BulwarkVault(payable(factory.createVault()));
        // 0.1 BTC, borrow 3,000 MUSD, keep 600 as the rescue reserve
        vault.openLoan{value: 0.1 ether}(3000e18, 600e18, address(0), address(0));
        // rescue below 160%, back to 180%, keeper fee 0.5%
        vault.setRule(1.6e18, 1.8e18, 50);
        vm.stopPrank();
    }

    receive() external payable {} // liquidation rewards land here

    function _icr() internal view returns (uint256) {
        return ITroveManager(TM).getCurrentICR(address(vault), uint256(MockOracle2(ORACLE).answer()));
    }

    function test_openSendsBorrowedMUSDToOwner() public view {
        assertEq(IERC20(MUSD).balanceOf(alice), 2400e18);
        assertEq(vault.reserve(), 600e18);
        assertEq(factory.vaultOf(alice), address(vault));
        assertEq(ITroveManager(TM).getTroveStatus(address(vault)), 1);
    }

    function test_rescueRevertsWhenHealthy() public {
        uint256 icr = _icr();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BulwarkVault.Healthy.selector, icr, 1.6e18));
        vault.rescue(address(0), address(0));
    }

    function test_rescueAfterPriceDrop() public {
        _mildDrop(); // BTC -1.25%: below a 250% trigger, no other Mezo loan under 110%
        uint256 before = _icr();
        console.log("ratio before rescue (1e16 = 1%)", before / 1e16);
        assertLt(before, 2.5e18);

        (bool can,, uint256 repayPreview, uint256 feePreview) = vault.previewRescue();
        assertTrue(can);

        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        uint256 afterIcr = _icr();
        console.log("ratio after rescue", afterIcr / 1e16);
        console.log("repaid MUSD", repaid / 1e18, "keeper fee (milli-MUSD)", fee / 1e15);

        assertEq(repaid, repayPreview);
        assertEq(fee, feePreview);
        assertApproxEqRel(afterIcr, 2.7e18, 0.002e18); // within 0.2% of target
        assertEq(IERC20(MUSD).balanceOf(keeper), fee);
        assertEq(fee, (repaid * 50) / 10_000);
        assertEq(vault.rescueCount(), 1);

        // Healthy again, so a second rescue is refused
        vm.prank(keeper);
        vm.expectRevert();
        vault.rescue(address(0), address(0));
    }

    function test_rescueCappedBySmallReserve() public {
        vm.prank(alice);
        vault.withdrawReserve(500e18); // only 100 MUSD left
        _mildDrop(); // BTC -1.25%: below a 250% trigger, no other Mezo loan under 110%
        uint256 before = _icr();
        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        assertLe(repaid + fee, 100e18);
        assertGt(_icr(), before); // partial rescue still helps
        assertLt(_icr(), 2.7e18);
    }

    function test_rescueRespectsMezoMinimumDebt() public {
        // Huge reserve and a high target: rescue must stop at Mezo's minimum debt, not revert
        deal(MUSD, alice, 10_000e18);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), type(uint256).max);
        vault.depositReserve(5_000e18);
        vault.setRule(3e18, 9e18, 50);
        vm.stopPrank();
        vm.prank(keeper);
        vault.rescue(address(0), address(0));
        (, uint256 debt) = vault.loan();
        assertGe(debt, 2000e18);
        assertLe(debt, 2002e18);
    }

    function test_onlyOwnerControls() public {
        vm.startPrank(keeper);
        vm.expectRevert(BulwarkVault.NotOwner.selector);
        vault.withdrawReserve(1);
        vm.expectRevert(BulwarkVault.NotOwner.selector);
        vault.setRule(1.6e18, 2e18, 50);
        vm.expectRevert(BulwarkVault.NotOwner.selector);
        vault.closeLoan();
        vm.stopPrank();
    }

    function test_badRulesRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(BulwarkVault.BadRule.selector);
        vault.setRule(1.1e18, 1.5e18, 50); // trigger too close to liquidation
        vm.expectRevert(BulwarkVault.BadRule.selector);
        vault.setRule(1.6e18, 1.5e18, 50); // target below trigger
        vm.expectRevert(BulwarkVault.BadRule.selector);
        vault.setRule(1.6e18, 1.8e18, 500); // fee above 2%
        vm.stopPrank();
    }

    function test_anyoneCanAddCollateral() public {
        uint256 before = _icr();
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        vault.addCollateral{value: 0.01 ether}(address(0), address(0));
        assertGt(_icr(), before);
    }

    function test_closeLoanReturnsBTC() public {
        deal(MUSD, alice, 5_000e18);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), type(uint256).max);
        vault.depositReserve(3_000e18);
        uint256 btcBefore = alice.balance;
        vault.closeLoan();
        vm.stopPrank();
        assertEq(ITroveManager(TM).getTroveStatus(address(vault)), 2); // closed by owner
        assertEq(alice.balance - btcBefore, 0.1 ether);
        assertEq(vault.reserve(), 0);
    }

    // ------------------------------------------------------------ v2: the reserve earns

    function test_reserveStartsEarningInStabilityPool() public view {
        assertTrue(vault.earning());
        assertEq(vault.liquidBps(), 2_500);
        assertEq(vault.reserveLiquid(), 150e18); // 25% stays on hand
        assertApproxEqAbs(vault.reserveEarning(), 450e18, 1e12);
        assertApproxEqAbs(vault.reserve(), 600e18, 1e12);
        assertEq(IStabilityPool(SP).deposits(address(vault)), 450e18);
    }

    function test_depositReserveIsStaked() public {
        deal(MUSD, alice, 500e18);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), type(uint256).max);
        vault.depositReserve(500e18);
        vm.stopPrank();
        assertApproxEqAbs(vault.reserveLiquid(), 275e18, 1e12);
        assertApproxEqAbs(vault.reserveEarning(), 825e18, 1e12);
    }

    function test_rescuePullsFromPool() public {
        _mildDrop(); // BTC -1.25%: below a 250% trigger, no other Mezo loan under 110%
        assertFalse(vault.poolLocked());
        uint256 before = _icr();
        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        assertGt(repaid, 0);
        assertApproxEqRel(_icr(), 2.7e18, 0.002e18);
        assertGt(_icr(), before);
        assertEq(IERC20(MUSD).balanceOf(keeper), fee);
        assertApproxEqAbs(vault.reserve(), 600e18 - repaid - fee, 1e12);
    }

    function test_rescueFallsBackWhenPoolLocked() public {
        // Only the 150 MUSD on hand is usable: the pool refuses withdrawals (as it does while
        // any Mezo loan is below 110%).
        vm.mockCallRevert(SP, abi.encodeWithSelector(IStabilityPool.withdrawFromSP.selector), "locked");
        MockOracle2(ORACLE).set(48_000e18);
        uint256 before = _icr();
        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        assertLe(repaid + fee, 150e18);
        assertGt(repaid, 149e18);
        assertGt(_icr(), before);
        assertEq(IERC20(MUSD).balanceOf(keeper), fee);
    }

    function test_withdrawReservePullsFromPool() public {
        vm.prank(alice);
        vault.withdrawReserve(200e18);
        assertEq(IERC20(MUSD).balanceOf(alice), 2600e18);
        assertApproxEqAbs(vault.reserve(), 400e18, 1e12);
    }

    function test_earningOffBringsReserveBack() public {
        vm.prank(alice);
        vault.setEarning(false, 2_500);
        assertFalse(vault.earning());
        assertApproxEqAbs(vault.reserveLiquid(), 600e18, 1e12);
        assertEq(vault.reserveEarning(), 0);
        // and new deposits stay on hand
        deal(MUSD, alice, 100e18);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), 100e18);
        vault.depositReserve(100e18);
        vm.stopPrank();
        assertApproxEqAbs(vault.reserveLiquid(), 700e18, 1e12);
    }

    function test_onlyOwnerSetsEarning() public {
        vm.prank(keeper);
        vm.expectRevert(BulwarkVault.NotOwner.selector);
        vault.setEarning(false, 2_500);
    }

    /// A real liquidation elsewhere on Mezo pays the pool BTC; harvest moves our share into the loan.
    function test_harvestMovesEarnedBTCIntoLoan() public {
        address bob = makeAddr("bulwark-risky-borrower");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        IOpen(BO).openTrove{value: 0.035 ether}(2000e18, address(0), address(0)); // ~126% at 80k
        MockOracle2(ORACLE).set(64_000e18); // BTC -20%: bob is under water, we are not
        ILiquidate(TM).liquidate(bob);

        uint256 pending = vault.pendingHarvest();
        console.log("BTC earned by the reserve (sats)", pending / 1e10);
        assertGt(pending, 0);
        (uint256 collBefore,) = vault.loan();
        vm.prank(keeper); // anyone can harvest
        uint256 btc = vault.harvest(address(0), address(0));
        (uint256 collAfter,) = vault.loan();
        assertEq(btc, pending);
        assertEq(collAfter - collBefore, pending);
        assertEq(vault.totalHarvested(), pending);
        vm.expectRevert(BulwarkVault.NothingToHarvest.selector);
        vault.harvest(address(0), address(0));
    }

    function test_closeLoanWithStakedReserve() public {
        deal(MUSD, alice, 5_000e18);
        vm.startPrank(alice);
        IERC20(MUSD).approve(address(vault), type(uint256).max);
        vault.depositReserve(3_000e18); // staked
        vault.closeLoan();
        vm.stopPrank();
        assertEq(ITroveManager(TM).getTroveStatus(address(vault)), 2);
        assertEq(vault.reserve(), 0);
        assertEq(IStabilityPool(SP).deposits(address(vault)), 0);
    }

    function _mildDrop() internal {
        vm.prank(alice);
        vault.setRule(2.5e18, 2.7e18, 50);
        MockOracle2(ORACLE).set(79_000e18);
    }

    function _liquidateUnderwater() internal returns (uint256 n) {
        uint256 price = uint256(MockOracle2(ORACLE).answer());
        address[] memory list = new address[](60);
        address cur = ISorted(ST).getLast();
        while (cur != address(0) && n < 60 && ITroveManager(TM).getCurrentICR(cur, price) < 1.1e18) {
            list[n++] = cur;
            cur = ISorted(ST).getPrev(cur);
        }
        assembly { mstore(list, n) }
        if (n > 0) IBatch(TM).batchLiquidateTroves(list);
        console.log("liquidated under-water loans", n);
    }

    /// The real crash case: BTC -40% leaves other Mezo loans under water, which locks the pool.
    /// The rescue still runs on the on-hand share, and once a keeper liquidates the under-water
    /// loans the pool unlocks and the rest of the reserve can rescue too.
    function test_crashRescueWithLockedThenUnlockedPool() public {
        vm.prank(alice);
        vault.setRule(2.5e18, 2.7e18, 50);
        MockOracle2(ORACLE).set(72_000e18); // BTC -10%: some testnet loans fall under 110%
        uint256 before = _icr();
        bool locked = vault.poolLocked();
        console.log("pool locked after the crash", locked);
        (, , uint256 previewRepay,) = vault.previewRescue();
        vm.prank(keeper);
        (uint256 repaid1,) = vault.rescue(address(0), address(0));
        assertEq(repaid1, previewRepay); // preview knows about the lock
        console.log("first rescue repaid (pool locked?)", repaid1 / 1e18);
        assertGt(_icr(), before);

        uint256 n;
        for (uint256 k = 0; k < 10 && vault.poolLocked(); k++) n += _liquidateUnderwater();
        console.log("under-water loans liquidated", n);
        assertFalse(vault.poolLocked());
        if (_icr() < 2.5e18) {
            vm.prank(keeper);
            vault.rescue(address(0), address(0));
        }
        console.log("ratio after", _icr() / 1e16);
        assertApproxEqRel(_icr(), 2.7e18, 0.01e18);
    }

    function test_rebalanceRestoresOnHandShare() public {
        _mildDrop(); // BTC -1.25%: below a 250% trigger, no other Mezo loan under 110%
        vm.prank(keeper);
        vault.rescue(address(0), address(0));
        vault.rebalance();
        uint256 r = vault.reserve();
        assertApproxEqAbs(vault.reserveLiquid(), (r * 2_500) / 10_000, 1e15);
    }

    // ------------------------------------------------------------ v2: redemption awareness

    function test_redemptionPositionMovesBackWhenSafer() public {
        (uint256 rank, uint256 ahead, uint256 total) = vault.redemptionPosition();
        console.log("rank", rank, "of", total);
        console.log("MUSD ahead of us", ahead / 1e18);
        assertGt(rank, 0);
        assertLe(rank, total);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vault.addCollateral{value: 5 ether}(address(0), address(0));
        (uint256 rank2, uint256 ahead2,) = vault.redemptionPosition();
        console.log("after adding BTC: rank", rank2, "MUSD ahead", ahead2 / 1e18);
        assertGt(rank2, rank);
        assertGt(ahead2, ahead);
    }
}
