// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GateVault.sol";

interface ITroveManager {
    function getCurrentICR(address, uint256) external view returns (uint256);
    function getTroveStatus(address) external view returns (uint256);
    function getEntireDebtAndColl(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
}

interface IHintHelpers {
    function getApproxHint(uint256 cr, uint256 numTrials, uint256 seed) external view returns (address, uint256, uint256);
}

interface ISortedTroves {
    function findInsertPosition(uint256 nicr, address prev, address next) external view returns (address, address);
}

/// Stand-in for Mezo's oracle precompile (0x7b7c...15), which a local fork cannot execute.
/// It returns the live testnet price read at fork time, and lets the test move the price.
contract MockOracle {
    int256 public answer;
    function set(int256 a) external { answer = a; }
    function decimals() external pure returns (uint8) { return 18; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract GatesTest is Test {
    address constant ORACLE = 0x7b7c000000000000000000000000000000000015;
    address constant BO = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TM = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant PF = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;

    GateVault vault;
    address user = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC", string("https://rpc.test.mezo.org")));
        int256 live = vm.envOr("LIVE_PRICE", int256(81676e18));
        vm.etch(ORACLE, address(new MockOracle()).code);
        MockOracle(ORACLE).set(live);
        vm.deal(user, 1 ether); // 1 test BTC (18 decimals)
        vm.prank(user);
        vault = new GateVault(BO, MUSD);
    }

    function test_gates() public {
        uint256 price = IPriceFeed(PF).fetchPrice();
        console.log("Gate 4a: price feed read, BTC/USD (1e18) =", price);

        // Gate 1: contract opens trove with native BTC as the borrower
        vm.prank(user);
        vault.open{value: 0.1 ether}(3000e18, address(0), address(0));
        assertEq(ITroveManager(TM).getTroveStatus(address(vault)), 1, "trove not active");
        uint256 icr0 = ITroveManager(TM).getCurrentICR(address(vault), price);
        (uint256 coll, uint256 principal, uint256 interest,,,) = ITroveManager(TM).getEntireDebtAndColl(address(vault));
        console.log("Gate 1 PASS: vault owns trove. coll(wei)=", coll);
        console.log("  principal=", principal, " interest=", interest);
        console.log("Gate 4b: ICR read (1e18 = 100%) =", icr0);
        uint256 musdHeld = IERC20Min(MUSD).balanceOf(address(vault));
        console.log("  MUSD minted into vault =", musdHeld);

        // Gate 2: repay from MUSD the vault holds; ICR must rise
        vault.repayFromReserve(500e18, address(0), address(0));
        uint256 icr1 = ITroveManager(TM).getCurrentICR(address(vault), price);
        console.log("Gate 2: ICR after repaying 500 MUSD =", icr1);
        assertGt(icr1, icr0, "ICR did not rise");
        assertEq(IERC20Min(MUSD).balanceOf(address(vault)), musdHeld - 500e18);

        // Bonus: anyone can top up collateral via the vault
        vm.deal(address(0xCAFE), 1 ether);
        vm.prank(address(0xCAFE));
        vault.topUp{value: 0.01 ether}(address(0), address(0));
        uint256 icr2 = ITroveManager(TM).getCurrentICR(address(vault), price);
        console.log("Bonus: ICR after keeper BTC top-up =", icr2);
        assertGt(icr2, icr1);
    }
}
