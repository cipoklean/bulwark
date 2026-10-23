// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BulwarkFactory} from "../src/BulwarkFactory.sol";
import {BulwarkVault} from "../src/BulwarkVault.sol";
import {ITroveManager, IERC20} from "../src/interfaces/IMezo.sol";

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

    BulwarkFactory factory;
    BulwarkVault vault;
    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC", string("https://rpc.test.mezo.org")));
        vm.etch(ORACLE, address(new MockOracle2()).code);
        MockOracle2(ORACLE).set(80_000e18);
        factory = new BulwarkFactory(BO, TM, PF, MUSD);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vault = BulwarkVault(payable(factory.createVault()));
        // 0.1 BTC, borrow 3,000 MUSD, keep 600 as the rescue reserve
        vault.openLoan{value: 0.1 ether}(3000e18, 600e18, address(0), address(0));
        // rescue below 160%, back to 180%, keeper fee 0.5%
        vault.setRule(1.6e18, 1.8e18, 50);
        vm.stopPrank();
    }

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
        MockOracle2(ORACLE).set(48_000e18); // BTC falls 40%
        uint256 before = _icr();
        console.log("ratio before rescue (1e16 = 1%)", before / 1e16);
        assertLt(before, 1.6e18);

        (bool can,, uint256 repayPreview, uint256 feePreview) = vault.previewRescue();
        assertTrue(can);

        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        uint256 afterIcr = _icr();
        console.log("ratio after rescue", afterIcr / 1e16);
        console.log("repaid MUSD", repaid / 1e18, "keeper fee (milli-MUSD)", fee / 1e15);

        assertEq(repaid, repayPreview);
        assertEq(fee, feePreview);
        assertApproxEqRel(afterIcr, 1.8e18, 0.002e18); // within 0.2% of target
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
        MockOracle2(ORACLE).set(48_000e18);
        uint256 before = _icr();
        vm.prank(keeper);
        (uint256 repaid, uint256 fee) = vault.rescue(address(0), address(0));
        assertLe(repaid + fee, 100e18);
        assertGt(_icr(), before); // partial rescue still helps
        assertLt(_icr(), 1.8e18);
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
}
