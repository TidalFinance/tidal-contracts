// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./matic/AccessControlMixin.sol";
import "./matic/ContextMixin.sol";
import "./matic/IChildToken.sol";
import "./matic/NativeMetaTransaction.sol";

import "./GovernanceToken.sol";

contract TidalTokenChild is
    GovernanceToken("Tidal Token", "TIDAL"),
    IChildToken,
    AccessControlMixin,
    NativeMetaTransaction,
    ContextMixin
{
    string constant public ERC712_VERSION = "1";

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    constructor(
        address childChainManager
    ) public {
        _setupContractId("TidalTokenChild");
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(DEPOSITOR_ROLE, childChainManager);
        _initializeEIP712("Tidal Token", ERC712_VERSION);
    }

    function burn(uint256 _amount) external {
        _burn(_msgSender(), _amount);
    }

    // This is to support Native meta transactions
    // never use msg.sender directly, use _msgSender() instead
    function _msgSender()
        internal
        override
        view
        returns (address payable sender)
    {
        return ContextMixin.msgSender();
    }

    /**
     * @notice called when token is deposited on root chain
     * @dev Should be callable only by ChildChainManager
     * Should handle deposit by minting the required amount for user
     * Make sure minting is done only by this function
     * @param user user address for whom deposit is being done
     * @param depositData abi encoded amount
     */
    function deposit(address user, bytes calldata depositData)
        external
        override
        only(DEPOSITOR_ROLE)
    {
        uint256 amount = abi.decode(depositData, (uint256));
        _mint(user, amount);
    }

    /**
     * @notice called when user wants to withdraw tokens back to root chain
     * @dev Should burn user's tokens. This transaction will be verified when exiting on root chain
     * @param amount amount of tokens to withdraw
     */
    function withdraw(uint256 amount) external {
        _burn(_msgSender(), amount);
    }
}
