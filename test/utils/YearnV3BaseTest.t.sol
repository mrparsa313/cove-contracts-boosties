// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.18;

import { BaseTest, console2 as console } from "test/utils/BaseTest.t.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MockStrategy } from "tokenized-strategy-periphery/test/mocks/MockStrategy.sol";
import { WrappedYearnV3Strategy } from "src/strategies/WrappedYearnV3Strategy.sol";
import { WrappedYearnV3StrategyCurveSwapper } from "src/strategies/WrappedYearnV3StrategyCurveSwapper.sol";

import { ReleaseRegistry } from "vault-periphery/registry/ReleaseRegistry.sol";
import { RegistryFactory } from "vault-periphery/registry/RegistryFactory.sol";
import { Registry as PeripheryRegistry } from "vault-periphery/registry/Registry.sol";

import { Gauge } from "src/veYFI/Gauge.sol";
import { GaugeFactory } from "src/veYFI/GaugeFactory.sol";
import { OYfi } from "src/veYFI/OYfi.sol";
import { Registry } from "src/veYFI/Registry.sol";

// Interfaces
import { IVotingYFI } from "src/interfaces/IVotingYFI.sol";
import { IVault } from "src/interfaces/IVault.sol";
import { IStrategy } from "tokenized-strategy/interfaces/IStrategy.sol";
import { IWrappedYearnV3Strategy } from "src/interfaces/IWrappedYearnV3Strategy.sol";

contract YearnV3BaseTest is BaseTest {
    using SafeERC20 for IERC20;

    ERC20 public baseAsset = ERC20(USDC);
    mapping(string => address) public deployedVaults;
    mapping(string => address) public deployedStrategies;

    address public admin;
    address public management;
    address public vaultManagement;
    address public performanceFeeRecipient;
    address public keeper;
    // Wrapped Vault addresses
    address public tpManagement;
    address public tpVaultManagement;
    address public tpPerformanceFeeRecipient;
    address public tpKeeper;

    address public oYFI;
    address public oYFIRewardPool;
    address public gaugeImpl;
    address public gaugeFactory;
    address public gaugeRegistry;

    // Yearn registry addresses
    address public yearnReleaseRegistry;
    address public yearnRegistryFactory;
    address public yearnRegistry;

    function setUp() public virtual override {
        // Fork ethereum mainnet at block 18172262 for consistent testing and to cache RPC calls
        // https://etherscan.io/block/18172262
        forkNetworkAt("mainnet", 18_172_262);
        super.setUp();

        _createYearnRelatedAddresses();
        _createThirdPartyRelatedAddresses();

        // create admin user that would be the default owner of deployed contracts unless specified
        admin = createUser("admin");

        setUpVotingYfiStack();
        setUpYfiRegistry();
    }

    function _createYearnRelatedAddresses() internal {
        // Create yearn related user addresses
        management = createUser("management");
        vaultManagement = createUser("vaultManagement");
        performanceFeeRecipient = createUser("performanceFeeRecipient");
        keeper = createUser("keeper");

        vm.label(ETH_VE_YFI, "veYFI");
        vm.label(ETH_YFI, "YFI");
    }

    function _createThirdPartyRelatedAddresses() internal {
        // Create third party related user addresses
        tpManagement = createUser("tpManagement");
        tpVaultManagement = createUser("tpVaultManagement");
        tpPerformanceFeeRecipient = createUser("tpPerformanceFeeRecipient");
        tpKeeper = createUser("tpKeeper");
    }

    /// VE-YFI related functions ///
    function setUpVotingYfiStack() public {
        oYFI = _deployOYFI(admin);
        oYFIRewardPool = _deployOYFIRewardPool(oYFI, block.timestamp + 1 days);
        gaugeImpl = _deployGaugeImpl(oYFI, oYFIRewardPool);
        gaugeFactory = _deployGaugeFactory(gaugeImpl);
        gaugeRegistry = _deployVeYFIRegistry(admin, gaugeFactory, oYFIRewardPool);
    }

    function _deployOYFI(address owner) internal returns (address) {
        vm.prank(owner);
        address oYfiAddr = address(new OYfi());
        vm.label(oYfiAddr, "OYFI");
        return oYfiAddr;
    }

    function _deployOYFIRewardPool(address oYfi, uint256 startTime) internal returns (address) {
        address addr = vyperDeployer.deployContract(
            "lib/veYFI/contracts/", "OYfiRewardPool", abi.encode(ETH_VE_YFI, oYfi, startTime)
        );
        vm.label(addr, "OYfiRewardPool");
        return addr;
    }

    function deployOptions(
        address oYfi,
        address owner,
        address priceFeed,
        address curvePool
    )
        public
        returns (address)
    {
        return vyperDeployer.deployContract(
            "lib/veYFI/contracts/", "Options", abi.encode(ETH_YFI, oYfi, ETH_VE_YFI, owner, priceFeed, curvePool)
        );
    }

    function _deployGaugeImpl(address _oYFI, address _oYFIRewardPool) internal returns (address) {
        return address(new Gauge(ETH_VE_YFI, _oYFI, _oYFIRewardPool));
    }

    function deployGaugeViaFactory(address vault, address owner, string memory label) public returns (address) {
        address newGauge = GaugeFactory(gaugeFactory).createGauge(vault, owner);
        vm.label(newGauge, label);
        return newGauge;
    }

    function _deployGaugeFactory(address gaugeImplementation) internal returns (address) {
        address gaugeFactoryAddr = address(new GaugeFactory(gaugeImplementation));
        vm.label(gaugeFactoryAddr, "GaugeFactory");
        return gaugeFactoryAddr;
    }

    function _deployVeYFIRegistry(
        address owner,
        address _gaugeFactory,
        address veYFIRewardPool
    )
        internal
        returns (address)
    {
        vm.prank(owner);
        return address(new Registry(ETH_VE_YFI, ETH_YFI, _gaugeFactory, veYFIRewardPool));
    }

    /// YFI registry related functions ///
    function setUpYfiRegistry() public {
        yearnReleaseRegistry = _deployYearnReleaseRegistry(admin);
        yearnRegistryFactory = _deployYearnRegistryFactory(admin, yearnReleaseRegistry);
        yearnRegistry = RegistryFactory(yearnRegistryFactory).createNewRegistry("TEST_REGISTRY", admin);

        address blueprint = vyperDeployer.deployBlueprint("lib/yearn-vaults-v3/contracts/", "VaultV3");
        bytes memory args = abi.encode("Vault V3 Factory 3.0.0", blueprint, admin);
        address factory = vyperDeployer.deployContract("lib/yearn-vaults-v3/contracts/", "VaultFactory", args);

        vm.prank(admin);
        ReleaseRegistry(yearnReleaseRegistry).newRelease(factory);
    }

    function _deployYearnReleaseRegistry(address owner) internal returns (address) {
        vm.prank(owner);
        address registryAddr = address(new ReleaseRegistry(owner));
        vm.label(registryAddr, "ReleaseRegistry");
        return registryAddr;
    }

    function _deployYearnRegistryFactory(address owner, address releaseRegistry) internal returns (address) {
        vm.prank(owner);
        address factoryAddr = address(new RegistryFactory(releaseRegistry));
        vm.label(factoryAddr, "RegistryFactory");
        return factoryAddr;
    }

    // Deploy a vault with given strategies. Uses vyper deployer to deploy v3 vault
    // strategies can be dummy ones or real ones
    // This is intended to spawn a vault that we have control over.
    function deployVaultV3(
        string memory vaultName,
        address asset,
        address[] memory strategies
    )
        public
        returns (address)
    {
        vm.prank(admin);
        address vault =
            PeripheryRegistry(yearnRegistry).newEndorsedVault(asset, vaultName, "tsVault", management, 10 days, 0);
        IVault _vault = IVault(vault);

        vm.prank(management);
        // Give the vault manager all the roles
        _vault.set_role(vaultManagement, 8191);

        // Set deposit limit to max
        vm.prank(vaultManagement);
        _vault.set_deposit_limit(type(uint256).max);

        // Add strategies to vault
        for (uint256 i = 0; i < strategies.length; i++) {
            addStrategyToVault(_vault, IStrategy(strategies[i]));
        }

        // Label the vault
        deployedVaults[vaultName] = vault;
        vm.label(vault, vaultName);

        return vault;
    }

    function addStrategyToVault(IVault _vault, IStrategy _strategy) public {
        vm.prank(vaultManagement);
        _vault.add_strategy(address(_strategy));

        vm.prank(vaultManagement);
        _vault.update_max_debt_for_strategy(address(_strategy), type(uint256).max);
    }

    function setUpStrategy(string memory name, address asset) public returns (IStrategy) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategy _strategy = IStrategy(address(new MockStrategy(address(asset))));
        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);
        // Accept mangagement.
        vm.prank(management);
        _strategy.acceptManagement();

        // Label and store the strategy
        deployedStrategies[name] = address(_strategy);
        vm.label(address(_strategy), name);

        return _strategy;
    }

    // Deploy a strategy that wraps a vault.
    function setUpWrappedStrategy(string memory name, address asset) public returns (IWrappedYearnV3Strategy) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IWrappedYearnV3Strategy _wrappedStrategy =
            IWrappedYearnV3Strategy(address(new WrappedYearnV3Strategy(address(asset))));
        // set keeper
        _wrappedStrategy.setKeeper(tpKeeper);
        // set treasury
        _wrappedStrategy.setPerformanceFeeRecipient(tpPerformanceFeeRecipient);
        // set management of the strategy
        _wrappedStrategy.setPendingManagement(tpManagement);
        // Accept mangagement.
        vm.prank(tpManagement);
        _wrappedStrategy.acceptManagement();

        // Label and store the strategy
        // *name is "Wrapped Yearn V3 Strategy"
        deployedStrategies[name] = address(_wrappedStrategy);
        vm.label(address(_wrappedStrategy), name);

        return _wrappedStrategy;
    }

    // Deploy a strategy that wraps a vault.
    function setUpWrappedStrategyCurveSwapper(
        string memory name,
        address asset,
        address curvePool
    )
        public
        returns (IWrappedYearnV3Strategy)
    {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IWrappedYearnV3Strategy _wrappedStrategy =
            IWrappedYearnV3Strategy(address(new WrappedYearnV3StrategyCurveSwapper(address(asset), curvePool)));
        // set keeper
        _wrappedStrategy.setKeeper(tpKeeper);
        // set treasury
        _wrappedStrategy.setPerformanceFeeRecipient(tpPerformanceFeeRecipient);
        // set management of the strategy
        _wrappedStrategy.setPendingManagement(tpManagement);
        // Accept mangagement.
        vm.prank(tpManagement);
        _wrappedStrategy.acceptManagement();

        // Label and store the strategy
        // *name is "Wrapped Yearn V3 Strategy"
        deployedStrategies[name] = address(_wrappedStrategy);
        vm.label(address(_wrappedStrategy), name);

        return _wrappedStrategy;
    }

    function logStratInfo(address strategy) public view {
        IWrappedYearnV3Strategy wrappedYearnV3Strategy = IWrappedYearnV3Strategy(strategy);
        console.log("****************************************");
        console.log("price per share: ", wrappedYearnV3Strategy.pricePerShare());
        console.log("total assets: ", wrappedYearnV3Strategy.totalAssets());
        console.log("total supply: ", wrappedYearnV3Strategy.totalSupply());
        console.log("total debt: ", wrappedYearnV3Strategy.totalDebt());
        console.log("balance of test executor: ", wrappedYearnV3Strategy.balanceOf(address(this)));
        console.log("strat USDC balance: ", ERC20(USDC).balanceOf(address(wrappedYearnV3Strategy)));
    }

    function logVaultInfo(string memory name) public view {
        IVault deployedVault = IVault(deployedVaults[name]);
        console.log("****************************************");
        console.log(
            "current debt in strat: ",
            deployedVault.strategies(deployedStrategies["Wrapped YearnV3 Strategy"]).currentDebt
        );
        console.log("vault USDC balance: ", ERC20(USDC).balanceOf(address(deployedVault)));
        console.log("vault total debt: ", deployedVault.totalDebt());
        console.log("vault total idle assets: ", deployedVault.totalIdle());
    }

    function depositIntoStrategy(IWrappedYearnV3Strategy _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        baseAsset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IWrappedYearnV3Strategy _strategy, address _user, uint256 _amount) public {
        airdrop(baseAsset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function addDebtToStrategy(IVault _vault, IStrategy _strategy, uint256 _amount) public {
        vm.prank(vaultManagement);
        _vault.update_debt(address(_strategy), _amount);
    }
}
