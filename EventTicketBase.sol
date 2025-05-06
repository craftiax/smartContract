// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@prb/math/src/Common.sol";

contract EventTicketBase is ERC1155, Ownable, ReentrancyGuard, Pausable {
    // Enums
    enum PaymentCurrency {
        ETH,
        USD
    }
    enum EventStatus {
        DRAFT,
        PUBLISHED,
        CANCELLED,
        COMPLETED
    }

    struct EventTier {
        uint256 price;
        uint256 maxQuantity;
        uint256 soldCount;
        bool isActive;
        uint256 maxTicketsPerUser;  // Maximum tickets a single user can mint
        mapping(address => uint256) userMintedCount;  // Track how many tickets each user has minted
    }

    struct Event {
        // Event details
        string name; // The name of the event
        string description; // A description of the event
        uint256 startTime; // The start time of the event in Unix timestamp
        uint256 endTime; // The end time of the event in Unix timestamp
        uint256 saleStartTime; // When ticket sales begin
        uint256 saleEndTime; // When ticket sales end
        address organizer; // The address of the event organizer
        string organizer_username; // The username of the event organizer
        EventStatus status; // The current status of the event (Draft, Published, Cancelled, Completed)
        PaymentCurrency currency; // The currency in which tickets are sold (ETH or USD)
        bool isActive; // Indicates if the event is currently active
        bool isRefundable; // Indicates if tickets for this event are refundable

        // Event tiers
        mapping(string => EventTier) tiers; // Mapping of tier IDs to their details
        string[] tierIds; // Array of tier IDs for easy iteration

        // Refund tracking
        mapping(address => bool) hasRefunded; // Mapping to track if a user has refunded their tickets
    }

    // Constants and State variables
    uint256 internal immutable MAX_TIERS;
    uint256 internal immutable MIN_PRICE;
    uint256 internal immutable MAX_PRICE;
    uint8 internal immutable USDC_DECIMALS;
    uint8 internal constant PRICE_DECIMALS = 18;

    IERC20 public immutable usdToken;
    mapping(string => Event) internal events;
    mapping(address => uint256) internal organizerBalances;
    mapping(address => uint256) internal organizerUSDBalances;

    // Events
    event EventCreated(string eventId, address indexed creator, string name);
    event TicketMinted(
        string eventId,
        string tierId,
        address indexed recipient,
        uint256 price
    );
    event FeesWithdrawn(
        address indexed recipient,
        uint256 ethAmount,
        uint256 usdAmount
    );
    event OrganizerBalanceUpdated(
        address indexed organizer,
        uint256 ethBalance,
        uint256 usdBalance
    );
    event EventStatusUpdated(string eventId, EventStatus status);
    event TierStatusUpdated(string eventId, string tierId, bool isActive);
    event CommissionUpdated(uint256 oldPercentage, uint256 newPercentage);
    event PlatformAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event CommissionAddressUpdated(address indexed oldAddress, address indexed newAddress);

    // Change from constant to public state variable
    uint256 public COMMISSION_PERCENTAGE = 300; // 3% represented as basis points (3.00%)
    address public platformCommissionAddress;

    constructor(address _usdToken) ERC1155("") Ownable(msg.sender) {
        usdToken = IERC20(_usdToken);
        MAX_TIERS = 10;
        MIN_PRICE = 0; // Changed to 0 to allow free tickets
        MAX_PRICE = 100 ether;
        USDC_DECIMALS = IERC20Metadata(_usdToken).decimals();
        platformCommissionAddress = msg.sender; // Initially set to contract owner
    }

    // Internal helper functions
    function validateEventTimes(
        uint256 startTime,
        uint256 endTime,
        uint256 saleStartTime,
        uint256 saleEndTime
    ) internal view {
        require(startTime < endTime, "End time must be after start time");
        require(saleStartTime < saleEndTime, "Invalid sale times");
        require(block.timestamp <= saleEndTime, "Sale end time must be in future");
        require(startTime > block.timestamp, "Start time must be in future");
        require(saleStartTime <= startTime, "Sale must end before or at event start");
        require(saleEndTime <= endTime, "Sale must end before or at event end");
    }

    function validateTierData(
        uint256[] memory tierPrices,
        uint256[] memory tierSupplies
    ) internal view {
        require(
            tierPrices.length == tierSupplies.length,
            "Tier arrays must match"
        );
        require(
            tierPrices.length > 0 && tierPrices.length <= MAX_TIERS,
            "Invalid tier count"
        );

        for (uint256 i = 0; i < tierPrices.length; i++) {
            require(
                tierPrices[i] >= MIN_PRICE && tierPrices[i] <= MAX_PRICE,
                "Invalid price"
            );
            require(tierSupplies[i] > 0, "Supply must be positive");
        }
    }

    function isEventActive(Event storage event_) internal view returns (bool) {
        return
            event_.status == EventStatus.PUBLISHED &&
            block.timestamp >= event_.saleStartTime &&
            block.timestamp <= event_.saleEndTime;
    }

    function _scaleAmount(uint256 amount) internal virtual view returns (uint256) {
        // If amount is 0, return 0 without scaling
        if (amount == 0) return 0;
        
        int256 decimalDiff = int256(uint256(USDC_DECIMALS)) - int256(uint256(PRICE_DECIMALS));
        if (decimalDiff < 0) {
            return amount / (10 ** uint256(-decimalDiff));
        } else {
            return amount * (10 ** uint256(decimalDiff));
        }
    }

    function _processPayment(
        uint256 scaledAmount,
        PaymentCurrency currency,
        address sender
    ) internal returns (bool) {
        require(sender != address(0), "Invalid sender address");
        // Allow zero amount payments for free tickets
        if (scaledAmount == 0) return true;
        
        if (currency == PaymentCurrency.USD) {
            require(
                usdToken.balanceOf(sender) >= scaledAmount,
                "Insufficient USDC balance"
            );
            return usdToken.transferFrom(sender, address(this), scaledAmount);
        } else if (currency == PaymentCurrency.ETH) {
            return msg.value == scaledAmount;
        }
        revert("Invalid currency");
    }

    function _handleCommissionAndPayment(
        Event storage event_,
        uint256 scaledAmount,
        PaymentCurrency currency
    ) internal virtual {
        // Skip commission for free tickets
        if (scaledAmount == 0) {
            return;
        }

        uint256 commissionAmount;
        uint256 creatorAmount;
        
        unchecked {
            commissionAmount = (scaledAmount * COMMISSION_PERCENTAGE) / 10000;
            creatorAmount = scaledAmount - commissionAmount;
        }

        if (currency == PaymentCurrency.USD) {
            require(usdToken.transfer(platformCommissionAddress, commissionAmount), 
                "Commission USDC transfer failed");
            require(usdToken.transfer(event_.organizer, creatorAmount), 
                "Creator USDC transfer failed");
        } else {
            (bool commissionSuccess, ) = payable(platformCommissionAddress).call{value: commissionAmount}("");
            require(commissionSuccess, "Commission ETH transfer failed");
            
            (bool creatorSuccess, ) = payable(event_.organizer).call{value: creatorAmount}("");
            require(creatorSuccess, "Creator ETH transfer failed");
        }
    }

    // Function to update platform commission address - only owner
    function updatePlatformCommissionAddress(address newAddress) external virtual onlyOwner {
        require(newAddress != address(0), "Invalid commission address");
        require(newAddress != platformCommissionAddress, "Same address provided");
        
        address oldAddress = platformCommissionAddress;
        platformCommissionAddress = newAddress;
        
        emit CommissionAddressUpdated(oldAddress, newAddress);
    }
}
