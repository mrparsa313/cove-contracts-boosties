// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { YearnV3BaseTest } from "./utils/YearnV3BaseTest.t.sol";
import { console2 as console } from "test/utils/BaseTest.t.sol";
import { IStrategy } from "src/interfaces/deps/yearn/tokenized-strategy/IStrategy.sol";
import { IVault } from "src/interfaces/deps/yearn/yearn-vaults-v3/IVault.sol";
import { IWrappedYearnV3Strategy } from "src/interfaces/IWrappedYearnV3Strategy.sol";
import { ERC20 } from "@openzeppelin-5.0/contracts/token/ERC20/ERC20.sol";
import { ICurveBasePool } from "../src/interfaces/deps/curve/ICurveBasePool.sol";
import { MockChainLinkOracle } from "./mocks/MockChainLinkOracle.sol";
import { Errors } from "src/libraries/Errors.sol";

contract WrappedStrategyCurveSwapperTest is YearnV3BaseTest {
    IStrategy public mockStrategy;
    IWrappedYearnV3Strategy public wrappedYearnV3Strategy;
    IVault public deployedVault;
    MockChainLinkOracle public mockDAIOracle;
    address public constant CHAINLINK_DAI_USD_MAINNET = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address public constant CHAINLINK_USDC_USD_MAINNET = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Addresses
    address public alice;

    function setUp() public override {
        super.setUp();

        alice = createUser("alice");

        // The underlying vault accepts DAI, while the wrapped strategy accepts USDC
        mockStrategy = setUpStrategy("Mock DAI Strategy", MAINNET_DAI);
        wrappedYearnV3Strategy =
            setUpWrappedStrategyCurveSwapper("Wrapped YearnV3 Strategy", MAINNET_USDC, MAINNET_CRV3POOL);
        vm.label(address(wrappedYearnV3Strategy), "Wrapped YearnV3 Strategy");
        address[] memory strategies = new address[](1);
        strategies[0] = address(mockStrategy);
        deployVaultV3("DAI Vault", MAINNET_DAI, strategies);
        deployedVault = IVault(deployedVaults["DAI Vault"]);
        vm.startPrank(users["tpManagement"]);
        wrappedYearnV3Strategy.setYieldSource(deployedVaults["DAI Vault"]);
        // create new user to be the staking delegate
        createUser("stakingDelegate");
        wrappedYearnV3Strategy.setStakingDelegate(users["stakingDelegate"]);
        // set the oracle for USDC and DAI
        wrappedYearnV3Strategy.setOracle(MAINNET_DAI, CHAINLINK_DAI_USD_MAINNET);
        wrappedYearnV3Strategy.setOracle(MAINNET_USDC, CHAINLINK_USDC_USD_MAINNET);
        // set the swap parameters
        wrappedYearnV3Strategy.setSwapParameters(99_500, 1 days);
        vm.stopPrank();
    }

    function testFuzz_deposit(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount < 1e13);
        deal({ token: MAINNET_USDC, to: users["alice"], give: amount });
        vm.startPrank(users["alice"]);
        ERC20(MAINNET_USDC).approve(address(wrappedYearnV3Strategy), amount);
        // deposit into strategy happens
        wrappedYearnV3Strategy.deposit(amount, users["alice"]);
        // check for expected changes
        uint256 ysdBalance = deployedVault.balanceOf(wrappedYearnV3Strategy.yearnStakingDelegateAddress());
        vm.stopPrank();
        require(ERC20(MAINNET_USDC).balanceOf(users["alice"]) == 0, "alice still has USDC");
        uint256 minAmountFromCurve = ICurveBasePool(MAINNET_CRV3POOL).get_dy(1, 0, amount);
        require(
            ysdBalance >= minAmountFromCurve - (minAmountFromCurve * 0.05e18 / 1e18),
            "vault shares not given to delegate"
        );
        require(deployedVault.totalSupply() == ysdBalance, "vault total_supply did not update correctly");
        require(wrappedYearnV3Strategy.balanceOf(users["alice"]) == amount, "Deposit was not successful");
    }

    function testFuzz_deposit_revertsSlippageTooHigh_tooLargeDeposit(uint256 amount) public {
        vm.assume(amount > 1e14);
        deal({ token: MAINNET_USDC, to: users["alice"], give: amount });
        vm.startPrank(users["alice"]);
        ERC20(MAINNET_USDC).approve(address(wrappedYearnV3Strategy), amount);
        vm.expectRevert();
        wrappedYearnV3Strategy.deposit(amount, users["alice"]);
    }

    function test_deposit_revertsSlippageTooHigh() public {
        vm.startPrank(users["tpManagement"]);
        // Setup oracles with un-pegged price
        mockDAIOracle = new MockChainLinkOracle(1e6);
        // set the oracle for USDC and DAI
        wrappedYearnV3Strategy.setOracle(MAINNET_DAI, address(mockDAIOracle));
        vm.stopPrank();
        uint256 amount = 1e8; // 100 USDC
        deal({ token: MAINNET_USDC, to: users["alice"], give: amount });
        mockDAIOracle.setTimestamp(block.timestamp);
        mockDAIOracle.setPrice(1e5);
        vm.startPrank(users["alice"]);
        ERC20(MAINNET_USDC).approve(address(wrappedYearnV3Strategy), amount);
        // deposit into strategy happens
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageTooHigh.selector));
        wrappedYearnV3Strategy.deposit(amount, users["alice"]);
    }

    function test_deposit_revertsOracleOutdated() public {
        vm.startPrank(users["tpManagement"]);
        // Setup oracles with un-pegged price
        mockDAIOracle = new MockChainLinkOracle(1e6);
        // set the oracle for USDC and DAI
        wrappedYearnV3Strategy.setOracle(MAINNET_DAI, address(mockDAIOracle));
        vm.stopPrank();
        uint256 amount = 1e8; // 100 USDC
        deal({ token: MAINNET_USDC, to: users["alice"], give: amount });
        mockDAIOracle.setTimestamp(block.timestamp - 2 days);
        vm.startPrank(users["alice"]);
        ERC20(MAINNET_USDC).approve(address(wrappedYearnV3Strategy), amount);
        // deposit into strategy happens
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleOudated.selector));
        wrappedYearnV3Strategy.deposit(amount, users["alice"]);
    }
}
