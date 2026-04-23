// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ERC20Token.sol";

contract ERC20TokenTest is Test {
    ERC20Token token;

    function setUp() public {
        token = new ERC20Token(1000);
    }

    function testInitialSupply() public {
        assertEq(token.totalSupply(), 1000 * 10**18);
        assertEq(token.balanceOf(address(this)), 1000 * 10**18);
    }

    function testTransfer() public {
        token.transfer(address(1), 100);
        assertEq(token.balanceOf(address(1)), 100);
    }
}