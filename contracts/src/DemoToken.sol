// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice TESTNET ONLY. Worthless demo $PEGGOY for practice on Robinhood Chain testnet: anyone can take
///         10,000 per call from the faucet. Never deployed on mainnet (the real token is launched on Pons).
contract DemoToken is ERC20 {
    uint256 public constant DRIP = 10_000e18;

    constructor() ERC20("Test PEGGOY", "tPEGGOY") {
        require(block.chainid != 4663, "testnet only");
    }

    function faucet() external {
        _mint(msg.sender, DRIP);
    }
}
