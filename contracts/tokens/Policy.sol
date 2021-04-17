// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IBuyer.sol";
import "../interfaces/IPolicy.sol";


// This token is owned by Buyer.
// Every asset needs have a Policy deployed.
contract Policy is ERC1155, IPolicy, Ownable {

    IBuyer public buyer;

    // assetIndex => week => id
    mapping(uint16 => mapping(uint256 => uint256)) public idMap;

    // id => assetIndex
    mapping(uint256 => uint16) public idToAssetIndex;

    // id => week
    mapping(uint256 => uint256) public idToWeek;

    uint256 public nextId = 1;

    constructor (
        string memory uri_,
        IBuyer buyer_
    ) ERC1155(uri_) public {
        buyer = buyer_;
    }

    function getCurrentWeek() public view returns(uint256) {
        return now.div(7 days);
    }

    function mint(uint16 assetIndex_) public {
        require(buyer.isUserCovered(_msgSender()), "Not covered");
        uint256 currentWeek = getCurrentWeek();

        uint256 id;
        if (idMap[assetIndex_][currentWeek] == 0) {
            id = nextId++;
            idMap[assetIndex_][currentWeek] = id;
            idToAssetIndex[id] = assetIndex_;
            idToWeek[id] = currentWeek;
        } else {
            id = idMap[assetIndex_][currentWeek];
        }

        uint256 delta = buyer.currentSubscription(_msgSender(), assetIndex_).sub(balanceOf(_msgSender(), id));

        bytes memory empty;
        _mint(_msgSender(), id, delta, empty);
    }
}
