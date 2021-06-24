// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../common/BaseRelayRecipient.sol";

import "../interfaces/IRegistry.sol";

// This token is owned by Timelock.
contract TidalToken is ERC20("Tidal Token", "TIL"), BaseRelayRecipient {

    string public override versionRecipient = "1.0.0";

    IRegistry public registry;

    constructor(IRegistry registry_) public {
        registry = registry_;
        _mint(msg.sender, 2e28);  // 20 billion, 18 decimals
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    function burn(uint256 _amount) external {
        _burn(_msgSender(), _amount);
    }
}
