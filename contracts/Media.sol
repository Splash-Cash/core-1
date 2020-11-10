pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import {ERC721Burnable} from "./ERC721Burnable.sol";
import {ERC721} from "./ERC721.sol";
import {EnumerableSet} from  "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Decimal} from "./Decimal.sol";
import {Market} from "./Market.sol";

contract Media is ERC721Burnable {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    // Address for the auction
    address public _auctionContract;

    // Mapping from token to previous owner of the token
    mapping(uint256 => address) public previousTokenOwners;

    // Mapping from token id to creator address
    mapping(uint256 => address) public tokenCreators;

    // Mapping from creator address to their (enumerable) set of created tokens
    mapping(address => EnumerableSet.UintSet) private _creatorTokens;

    // Mapping from token id to sha256 hash of content
    mapping(uint256 => bytes32) public tokenContentHashes;

    // Mapping from contentHash to bool
    mapping(bytes32 => bool) private _contentHashes;

    //keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    bytes32 public DOMAIN_SEPARATOR;

    // Mapping from address to token id to permit nonce
    mapping (address => mapping (uint256 => uint256)) public permitNonces;

    Counters.Counter private _tokenIdTracker;

    event BidCreated(
        uint256 tokenId,
        address bidder
    );

    event AskCreated(
        uint256 tokenId,
        address owner,
        uint256 amount,
        address currency,
        uint256 currencyDecimals
    );

    // Event indicating uri was updated.
    event TokenURIUpdated(uint256 indexed _tokenId, address owner, string  _uri);

    modifier onlyExistingToken (uint256 tokenId) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        _;
    }

    modifier onlyTokenWithContentHash (uint256 tokenId) {
        require(tokenContentHashes[tokenId] != "", "Media: token does not have hash of created content");
        _;
    }

    modifier onlyApprovedOrOwner(address spender, uint256 tokenId) {
        require(_isApprovedOrOwner(spender, tokenId), "Media: Only approved or owner");
        _;
    }

    modifier onlyAuction() {
        require(msg.sender == _auctionContract, "Media: only market contract");
        _;
    }

    modifier onlyTokenCreator(uint256 tokenId) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        require(tokenCreators[tokenId] == msg.sender, "Media: caller is not creator of token");
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        require(msg.sender == owner, "Media: caller is not owner of token");
        _;
    }

    modifier onlyTokenCreated(uint256 tokenId) {
        require(_tokenIdTracker.current() >= tokenId, "Media: token with that id does not exist");
        _;
    }

    modifier onlyValidContentHash(bytes32 contentHash) {
        require(contentHash != "", "Media: content hash must not be empty");
        require(_contentHashes[contentHash] == false, "Media: a token has already been created with this content hash");
        _;
    }

    constructor(address auctionContract) public ERC721("Media", "MEDIA") {
        _auctionContract = auctionContract;
        DOMAIN_SEPARATOR = initDomainSeparator("Media", "1");
    }

    /**
    * @dev Creates a new token for `creator`. Its token ID will be automatically
    * assigned (and available on the emitted {IERC721-Transfer} event), and the token
    * URI autogenerated based on the base URI passed at construction.
    *
    * See {ERC721-_safeMint}.
    */
    function mint(
        address creator,
        string memory tokenURI,
        bytes32 contentHash,
        Market.BidShares
        memory bidShares
    )
        public
        onlyValidContentHash(contentHash)
    {
        // We cannot just use balanceOf to create the new tokenId because tokens
        // can be burned (destroyed), so we need a separate counter.
        uint256 tokenId = _tokenIdTracker.current();

        _safeMint(creator, tokenId);
        _tokenIdTracker.increment();
        _setContentHash(tokenId, contentHash);
        _setTokenURI(tokenId, tokenURI);
        _creatorTokens[creator].add(tokenId);
        _contentHashes[contentHash] = true;

        tokenCreators[tokenId] = creator;
        previousTokenOwners[tokenId] = creator;
        Market(_auctionContract).addBidShares(tokenId, bidShares);
    }

    function auctionTransfer(uint256 tokenId, address bidder)
        public
        onlyAuction
    {
        previousTokenOwners[tokenId] = ownerOf(tokenId);
        _safeTransfer(ownerOf(tokenId), bidder, tokenId, '');
    }

    function setAsk(uint256 tokenId, Market.Ask memory ask)
        public
        onlyApprovedOrOwner(msg.sender, tokenId)
    {
        Market(_auctionContract).setAsk(tokenId, ask);
    }

    function setBid(uint256 tokenId, Market.Bid memory bid)
        public
        onlyExistingToken(tokenId)
    {
        Market(_auctionContract).setBid(tokenId, bid);
    }

    function removeBid(uint256 tokenId)
        public
        onlyTokenCreated(tokenId)
    {
        Market(_auctionContract).removeBid(tokenId, msg.sender);
    }

    function acceptBid(uint256 tokenId, Market.Bid memory bid)
        onlyApprovedOrOwner(msg.sender, tokenId)
        public
    {
        Market(_auctionContract).acceptBid(tokenId, bid);
    }

    function burn(uint256 tokenId)
        public
        override
        onlyTokenOwner(tokenId)
        onlyTokenCreator(tokenId)
    {
        _burn(tokenId);
    }

    function updateTokenURI(uint256 tokenId, string memory tokenURI)
        public
        onlyTokenOwner(tokenId)
        onlyTokenWithContentHash(tokenId)
    {
        _setTokenURI(tokenId, tokenURI);
        emit TokenURIUpdated(tokenId, msg.sender, tokenURI);
    }

    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        onlyExistingToken(tokenId)
        external
    {
        require(deadline == 0 || deadline >= block.timestamp, "Media: Permit expired");
        require(spender != address(0), "Media: spender cannot be 0x0");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        spender,
                        tokenId,
                        permitNonces[ownerOf(tokenId)][tokenId]++,
                        deadline
                    )
                )
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);

        require(
            recoveredAddress != address(0)  && ownerOf(tokenId) == recoveredAddress,
            "Media: Signature invalid"
        );

        _approve(spender, tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        onlyTokenCreated(tokenId)
        returns (string memory)
    {
        string memory _tokenURI = _tokenURIs[tokenId];

        // If there is no base URI, return the token URI.
        if (bytes(_baseURI).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(_baseURI, _tokenURI));
        }
        // If there is a baseURI but no tokenURI, concatenate the tokenID to the baseURI.
        return string(abi.encodePacked(_baseURI, tokenId.toString()));
    }

    function _setContentHash(uint256 tokenId, bytes32 contentHash)
        internal
        virtual
        onlyExistingToken(tokenId)
    {
        tokenContentHashes[tokenId] = contentHash;
    }

    function _burn(uint256 tokenId)
        internal
        override
    {
        address owner = ownerOf(tokenId);

        _beforeTokenTransfer(owner, address(0), tokenId);
        _approve(address(0), tokenId);
        _holderTokens[owner].remove(tokenId);
        _tokenOwners.remove(tokenId);

        emit Transfer(owner, address(0), tokenId);
    }

    /**
     * @dev Initializes EIP712 DOMAIN_SEPARATOR based on the current contract and chain ID.
     */
    function initDomainSeparator(
        string memory name,
        string memory version
    )
        internal
        returns (bytes32)
    {
        uint256 chainID;
        /* solium-disable-next-line */
        assembly {
            chainID := chainid()
        }

        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainID,
                address(this)
            )
        );
    }
}