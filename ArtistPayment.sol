// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ArtistPayment is ReentrancyGuard, Ownable {
    // Pack related storage variables together
    address public craftiaxAddress;
    uint96 public craftiaxFeePercentage;
    
    // Maximum fee percentage allowed (e.g., 20%)
    uint256 public constant MAX_FEE_PERCENTAGE = 20;
    
    // Track verified artists
    mapping(address => bool) public isVerifiedArtist;
    
    // Pack USDC decimals with payment limits
    uint8 private immutable USDC_DECIMALS;
    
    // Add payment currency enum
    enum PaymentCurrency { ETH, USD }
    
    // Add USDC token interface
    IERC20 public immutable usdToken;

    // Update payment limits to include USDC
    struct PaymentLimits {
        uint256 minPayment;
        uint256 maxPayment;
        uint256 verifiedMaxPayment;
    }
    
    PaymentLimits public ethLimits;
    PaymentLimits public usdcLimits;

    event PaymentProcessed(
        address indexed artist,
        uint256 artistAmount,
        uint256 craftiaxFee,
        bool isVerified
    );
    
    event FeeUpdated(uint256 newFee);
    event CraftiaxAddressUpdated(address newAddress);
    event ArtistVerificationStatusUpdated(address indexed artist, bool isVerified);
    event PaymentLimitsUpdated(
        uint256 generalMin,
        uint256 generalMax,
        uint256 verifiedMax
    );

    constructor(address initialOwner, address _usdToken) 
        Ownable(initialOwner) 
    {
        require(_usdToken != address(0), "Invalid USDC address");
        
        // Additional validations for USDC
        IERC20 token = IERC20(_usdToken);
        IERC20Metadata metadata = IERC20Metadata(_usdToken);
        
        // Check if it's a valid ERC20 contract
        try token.totalSupply() returns (uint256) {} catch {
            revert("Invalid ERC20 implementation");
        }
        
        // Verify USDC decimals
        uint8 decimals = metadata.decimals();
        require(decimals == 6, "Invalid USDC decimals");
        
        // Try to get symbol to verify it's USDC
        try metadata.symbol() returns (string memory symbol) {
            require(
                keccak256(abi.encodePacked(symbol)) == keccak256(abi.encodePacked("USDC")),
                "Invalid USDC token"
            );
        } catch {
            revert("Could not verify USDC token");
        }

        usdToken = token;
        USDC_DECIMALS = decimals;
        
        craftiaxAddress = 0x984D8DD1De91e00C0DAa5A34a0CC78C344012F1A;
        craftiaxFeePercentage = uint96(5);

        // Initialize ETH limits
        ethLimits = PaymentLimits({
            minPayment: 5000000000000 wei, // 0.000005 ETH
            maxPayment: 50000000000000000 wei, // 0.05 ETH
            verifiedMaxPayment: 250000000000000000 wei // 0.25 ETH
        });

        // Initialize USDC limits (assuming 6 decimals)
        usdcLimits = PaymentLimits({
            minPayment: 10000, // $0.01
            maxPayment: 100000000, // $100
            verifiedMaxPayment: 500000000 // $500
        });
    }

    function payArtist(
        address artistAddress,
        uint256 amount,
        PaymentCurrency currency,
        uint256 deadline
    ) external payable nonReentrant {
        // Validate inputs
        require(block.timestamp <= deadline, "Signature expired");
        require(artistAddress != address(0), "Invalid artist address");
        require(artistAddress != craftiaxAddress, "Artist cannot be Craftiax address");

        // Validate payment amount based on currency
        PaymentLimits storage limits = currency == PaymentCurrency.ETH ? ethLimits : usdcLimits;
        require(amount >= limits.minPayment, "Payment amount below minimum");
        
        uint256 maxAllowed = isVerifiedArtist[artistAddress] ? 
            limits.verifiedMaxPayment : 
            limits.maxPayment;
        require(amount <= maxAllowed, "Payment amount above maximum");

        // Calculate fees first to prevent overflow
        uint256 craftiaxFee;
        uint256 artistPayment;
        unchecked {
            craftiaxFee = (amount * uint256(craftiaxFeePercentage)) / 100;
            artistPayment = amount - craftiaxFee;
        }

        // Process payment based on currency
        if (currency == PaymentCurrency.USD) {
            require(msg.value == 0, "ETH not accepted for USDC payment");
            require(usdToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
            require(usdToken.transfer(artistAddress, artistPayment), "Artist USDC transfer failed");
            require(usdToken.transfer(craftiaxAddress, craftiaxFee), "Craftiax USDC transfer failed");
        } else {
            require(msg.value == amount, "Incorrect ETH amount");
            (bool successArtist, ) = payable(artistAddress).call{value: artistPayment}("");
            require(successArtist, "Failed to send ETH to artist");
            (bool successCraftiax, ) = payable(craftiaxAddress).call{value: craftiaxFee}("");
            require(successCraftiax, "Failed to send ETH to Craftiax");
        }

        emit PaymentProcessed(
            artistAddress, 
            artistPayment, 
            craftiaxFee,
            isVerifiedArtist[artistAddress]
        );
    }

    function updateCraftiaxAddress(address newAddress) external onlyOwner {
        require(newAddress != address(0), "Invalid address");
        require(newAddress != craftiaxAddress, "Same address provided");
        craftiaxAddress = newAddress;
        emit CraftiaxAddressUpdated(newAddress);
    }

    function updateFeePercentage(uint96 newFee) external onlyOwner {
        require(newFee <= MAX_FEE_PERCENTAGE, "Fee exceeds maximum allowed");
        craftiaxFeePercentage = newFee;
        emit FeeUpdated(newFee);
    }

    function setVerificationStatus(address artistAddress, bool status) 
        external 
        onlyOwner 
    {
        require(artistAddress != address(0), "Invalid artist address");
        require(isVerifiedArtist[artistAddress] != status, "Status already set");
        
        isVerifiedArtist[artistAddress] = status;
        emit ArtistVerificationStatusUpdated(artistAddress, status);
    }

    // Add array size limit for batch operations
    uint256 private constant MAX_BATCH_SIZE = 100;

    function setVerificationStatusBatch(address[] calldata artists, bool status)
        external
        onlyOwner
    {
        require(artists.length <= MAX_BATCH_SIZE, "Batch too large");
        for (uint256 i = 0; i < artists.length; i++) {
            require(artists[i] != address(0), "Invalid artist address");
            if (isVerifiedArtist[artists[i]] != status) {
                isVerifiedArtist[artists[i]] = status;
                emit ArtistVerificationStatusUpdated(artists[i], status);
            }
        }
    }

    function updatePaymentLimits(
        uint256 newGeneralMin,
        uint256 newGeneralMax,
        uint256 newVerifiedMax
    ) external onlyOwner {
        require(newGeneralMin > 0, "General min must be greater than 0");
        require(newGeneralMax > newGeneralMin, "General max must be greater than min");
        require(newVerifiedMax > newGeneralMax, "Verified max must be greater than general max");
        
        ethLimits = PaymentLimits({
            minPayment: newGeneralMin,
            maxPayment: newGeneralMax,
            verifiedMaxPayment: newVerifiedMax
        });
        
        emit PaymentLimitsUpdated(newGeneralMin, newGeneralMax, newVerifiedMax);
    }

    function updateUSDCPaymentLimits(
        uint256 newGeneralMin,
        uint256 newGeneralMax,
        uint256 newVerifiedMax
    ) external onlyOwner {
        require(newGeneralMin > 0, "General min must be greater than 0");
        require(newGeneralMax > newGeneralMin, "General max must be greater than min");
        require(newVerifiedMax > newGeneralMax, "Verified max must be greater than general max");
        
        usdcLimits = PaymentLimits({
            minPayment: newGeneralMin,
            maxPayment: newGeneralMax,
            verifiedMaxPayment: newVerifiedMax
        });
        
        emit PaymentLimitsUpdated(newGeneralMin, newGeneralMax, newVerifiedMax);
    }

    receive() external payable {}
}