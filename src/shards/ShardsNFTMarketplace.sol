// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IShardsNFTMarketplace} from "./IShardsNFTMarketplace.sol";
import {ShardsFeeVault} from "./ShardsFeeVault.sol";
import {DamnValuableToken} from "../DamnValuableToken.sol";
import {DamnValuableNFT} from "../DamnValuableNFT.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/**
 * @notice NFT marketplace where sellers offer NFTs, and buyers can collectively acquire pieces of them.
 *         Pieces of the NFT are represented by an integrated ERC1155 token.
 *         The marketplace charges sellers a 1% fee, stored in a secure on-chain vault.
 */
contract ShardsNFTMarketplace is IShardsNFTMarketplace, IERC721Receiver, ERC1155 {
    using FixedPointMathLib for uint256;

    /// @notice how much time buyers must wait before they can cancel
    uint32 public constant TIME_BEFORE_CANCEL = 1 days;

    /// @notice for how long can buyers cancel
    uint32 public constant CANCEL_PERIOD_LENGTH = 2 days;

    DamnValuableNFT public immutable nft;
    DamnValuableToken public immutable paymentToken;
    ShardsFeeVault public immutable feeVault;
    address public immutable oracle;

    uint64 public offerCount;
    uint256 public feesInBalance;
    uint256 public rate; // DVT per USDC
    mapping(uint64 offerId => Offer) public offers;
    mapping(uint256 nftId => uint64 offerId) public nftToOffers;
    mapping(uint64 offerdId => Purchase[]) public purchases;

    constructor(
        DamnValuableNFT _nft,
        DamnValuableToken _paymentToken,
        address _feeVaultImplementation,
        address _oracle,
        uint256 _initialRate
    ) ERC1155("") {
        paymentToken = _paymentToken;
        nft = _nft;
        oracle = _oracle;
        rate = _initialRate;

        // Deploy minimal proxy for fee vault. Then initialize it and approve max
        feeVault = ShardsFeeVault(Clones.clone(_feeVaultImplementation));
        feeVault.initialize(msg.sender, _paymentToken);
        paymentToken.approve(address(feeVault), type(uint256).max);
    }

    /**
     * @notice Called by sellers to open offers of one NFT, specifying number of units (a.k.a. "shards") and the total price.
     *         Sellers cannot withdraw offers. They're open until completely filled.
     * @param nftId ID of the NFT to offer
     * @param totalShards how many shards for the NFT
     * @param price total price, expressed in USDC units
     */
    function openOffer(uint256 nftId, uint256 totalShards, uint256 price) external returns (uint256) {
        if (price == 0) revert BadPrice();
        offerCount++; // offer IDs start at 1

        // create and store new offer
        offers[offerCount] = Offer({
            nftId: nftId,
            totalShards: totalShards,
            stock: totalShards,
            price: price,
            seller: msg.sender,
            isOpen: true
        });

        nftToOffers[nftId] = offerCount;

        emit NewOffer(offerCount, msg.sender, nftId, totalShards, price);

        _chargeFees(price);

        // pull NFT offered
        nft.safeTransferFrom(msg.sender, address(this), nftId, "");

        return offerCount;
    }

    /**
     * Caller can redeem and burn all shards to claim the associated NFT
     * @param nftId ID of the NFT to claim
     */
    function redeem(uint256 nftId) external {
        if (nft.ownerOf(nftId) != address(this)) revert UnknownNFT(nftId);
        uint64 offerId = nftToOffers[nftId];
        Offer memory offer = offers[offerId];
        if (offer.isOpen) revert StillOpen();

        delete offers[offerId];
        _burn(msg.sender, nftId, offer.totalShards);

        nft.safeTransferFrom(address(this), msg.sender, nftId, "");
    }

    function depositFees(bool stake) external {
        feeVault.deposit(feesInBalance, stake);
        feesInBalance = 0;
    }

    /**
     * @notice Called by buyers to partially/fully fill offers, paying in DVT.
     *         These purchases can be cancelled.
     */
    function fill(uint64 offerId, uint256 want) external returns (uint256 purchaseIndex) {
        Offer storage offer = offers[offerId];
        if (want == 0) revert BadAmount();
        if (offer.price == 0) revert UnknownOffer();
        if (want > offer.stock) revert OutOfStock();
        if (!offer.isOpen) revert NotOpened(offerId);

        offer.stock -= want;
        purchaseIndex = purchases[offerId].length;
        uint256 _currentRate = rate;
        purchases[offerId].push(
            Purchase({
                shards: want,
                rate: _currentRate,
                buyer: msg.sender,
                timestamp: uint64(block.timestamp),
                cancelled: false
            })
        );
        paymentToken.transferFrom(
            msg.sender, address(this), want.mulDivDown(_toDVT(offer.price, _currentRate), offer.totalShards)
        );
        if (offer.stock == 0) _closeOffer(offerId);
    }

    /**
     * @notice To cancel open offers once the waiting period is over.
     */
    function cancel(uint64 offerId, uint256 purchaseIndex) external {
        Offer storage offer = offers[offerId];
        Purchase storage purchase = purchases[offerId][purchaseIndex];
        address buyer = purchase.buyer;

        if (msg.sender != buyer) revert NotAllowed();
        if (!offer.isOpen) revert NotOpened(offerId);
        if (purchase.cancelled) revert AlreadyCancelled();
        if (
            purchase.timestamp + CANCEL_PERIOD_LENGTH < block.timestamp
                || block.timestamp > purchase.timestamp + TIME_BEFORE_CANCEL
        ) revert BadTime();

        offer.stock += purchase.shards;
        assert(offer.stock <= offer.totalShards); // invariant
        purchase.cancelled = true;

        emit Cancelled(offerId, purchaseIndex);

        paymentToken.transfer(buyer, purchase.shards.mulDivUp(purchase.rate, 1e6));
    }

    /**
     * @notice Allows an oracle account to set a new rate of DVT per USDC
     */
    function setRate(uint256 newRate) external {
        if (msg.sender != oracle) revert NotAllowed();
        if (newRate == 0 || rate == newRate) revert BadRate();
        rate = newRate;
    }

    /**
     * @notice Given a price in USDC, uses the oracle's rate to calculate the fees in DVT
     * @param price price in USDC units
     */
    function getFee(uint256 price, uint256 _rate) public pure returns (uint256) {
        uint256 fee = price.mulDivDown(1e6, 100e6); // 1% fee
        return _toDVT(fee, _rate);
    }

    function getOffer(uint64 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _chargeFees(uint256 price) private {
        uint256 feeAmount = getFee(price, rate);
        feesInBalance += feeAmount;
        emit Fee(feeAmount);
        paymentToken.transferFrom(msg.sender, address(this), feeAmount);
        assert(feesInBalance <= paymentToken.balanceOf(address(this))); // invariant
    }

    function _closeOffer(uint64 offerId) private {
        Offer memory offer = offers[offerId];
        Purchase[] memory _purchases = purchases[offerId];
        uint256 payment;

        for (uint256 i = 0; i < _purchases.length; i++) {
            Purchase memory purchase = _purchases[i];
            if (purchase.cancelled) continue;
            payment += purchase.shards.mulWadUp(purchase.rate);
            _mint({to: purchase.buyer, id: offer.nftId, value: purchase.shards, data: ""});
            assert(balanceOf(purchase.buyer, offer.nftId) <= offer.totalShards); // invariant
        }

        offers[offerId].isOpen = false;
        emit ClosedOffer(offerId);
        paymentToken.transfer(offer.seller, payment);
    }

    function _toDVT(uint256 _value, uint256 _rate) private pure returns (uint256) {
        return _value.mulDivDown(_rate, 1e6);
    }
}
