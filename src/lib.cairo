use starknet::ContractAddress;

use core::byte_array::ByteArray;
use core::traits::TryInto;
use core::result::ResultTrait;
use starknet::event::EventEmitter;
use openzeppelin::token::erc721::{ERC721Component, interface::{IERC721, IERC721CamelOnly}};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin::introspection::src5::SRC5Component;
use core::array::ArrayTrait;
use core::array::SpanTrait;
use core::dict::Felt252DictTrait;

const USER_ALREADY_REGISTERED: felt252 = 'User already registered';
const USER_NOT_REGISTERED: felt252 = 'User not registered';
const REWARDS_ALREADY_CLAIMED: felt252 = 'Rewards already claimed';
const NEED_FIVE_NFTS: felt252 = 'Need at least 5 NFTs to claim';
const STRK_TRANSFER_FAILED: felt252 = 'STRK transfer failed';

#[starknet::interface]
trait IGallerie<TContractState> {
    fn register_user(ref self: TContractState);
    fn submit_photo_grid(ref self: TContractState, grid_hash: felt252, grid_uri: ByteArray);
    fn get_user_nft_count(self: @TContractState, user: ContractAddress) -> u8;
    fn get_strk_rewards_claimed(self: @TContractState, user: ContractAddress) -> bool;
    fn claim_strk_rewards(ref self: TContractState);
    fn get_user_submissions(self: @TContractState, user: ContractAddress) -> felt252;
}

#[starknet::contract]
mod Gallerie {
    use super::{IGallerie, USER_ALREADY_REGISTERED, USER_NOT_REGISTERED, REWARDS_ALREADY_CLAIMED, 
                NEED_FIVE_NFTS, STRK_TRANSFER_FAILED};
    use starknet::{ContractAddress, get_caller_address};

    use starknet::storage::Map;

    use core::byte_array::ByteArray;
    use core::array::ArrayTrait;
    use core::traits::Into;
    use core::option::OptionTrait;
    use core::result::ResultTrait;
    use starknet::event::EventEmitter;
    use openzeppelin::token::erc721::{ERC721Component, interface::{IERC721, IERC721CamelOnly}};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::introspection::src5::SRC5Component;

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[storage]
    struct Storage {
        registered_users: Map::<ContractAddress, bool>,
        user_nft_counts: Map::<ContractAddress, u8>,  // Renamed for clarity
        strk_rewards_claimed: Map::<ContractAddress, bool>,
        next_token_id: u256,
        user_submissions: Map::<ContractAddress, felt252>,
        strk_token: ContractAddress,  // Renamed for consistency
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UserRegistered: UserRegistered,
        PhotoGridSubmitted: PhotoGridSubmitted,
        STRKRewardsClaimed: STRKRewardsClaimed,
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event
    }

    #[derive(Drop, starknet::Event)]
    struct UserRegistered {
        user: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct PhotoGridSubmitted {
        user: ContractAddress,
        token_id: u256,
        grid_hash: felt252,
        grid_uri: ByteArray
    }

    #[derive(Drop, starknet::Event)]
    struct STRKRewardsClaimed {
        user: ContractAddress,
        amount: u256
    }

    const STRK_REWARD_AMOUNT: u256 = 100000000000000000000; // 100 STRK (18 decimals)
    const NFT_THRESHOLD_FOR_REWARD: u8 = 5;

    #[constructor]
    fn constructor(
        ref self: ContractState, 
        strk_token: ContractAddress  // Parameter renamed to match storage
    ) {
        ERC721Component::InternalImpl::initializer(ref self.erc721, 'Gallerie NFT', 'GNFT');
        self.strk_token.write(strk_token);
        self.next_token_id.write(1);
    }

    #[abi(embed_v0)]
    impl ERC721Impl = ERC721Component::ERC721Impl<ContractState>;
    
    #[abi(embed_v0)]
    impl ERC721CamelOnlyImpl = ERC721Component::ERC721CamelOnlyImpl<ContractState>;
    
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[abi(embed_v0)]
    impl GallerieImpl of IGallerie<ContractState> {
        /// Registers a new user in the system
        fn register_user(ref self: ContractState) {
            let caller = get_caller_address();
            if self.registered_users.read(caller) {
                panic(array![USER_ALREADY_REGISTERED]);
            }
            
            self.registered_users.write(caller, true);
            self.user_nft_counts.write(caller, 0);
            self.strk_rewards_claimed.write(caller, false);
            self.user_submissions.write(caller, 0);
            
            self.emit(Event::UserRegistered(UserRegistered { user: caller }));
        }

        /// Submits a photo grid and mints an NFT
        fn submit_photo_grid(
            ref self: ContractState, 
            grid_hash: felt252, 
            grid_uri: ByteArray
        ) {
            let caller = get_caller_address();
            //assert(!self.registered_users.read(caller), USER_NOT_REGISTERED;
            
            let token_id = self.next_token_id.read();
            self.next_token_id.write(token_id + 1);
            
            // Mint NFT
            ERC721Component::InternalImpl::_mint(ref self.erc721, caller, token_id);
            
            // Update user's NFT count
            let current_count = self.user_nft_counts.read(caller);
            self.user_nft_counts.write(caller, current_count + 1);
            
            // Store submission
            self.user_submissions.write(caller, grid_hash);
            
            self.emit(Event::PhotoGridSubmitted(PhotoGridSubmitted {
                user: caller,
                token_id,
                grid_hash,
                grid_uri
            }));
        }

        /// Returns the NFT count for a user
        fn get_user_nft_count(self: @ContractState, user: ContractAddress) -> u8 {
            self.user_nft_counts.read(user)
        }

        /// Checks if user has claimed STRK rewards
        fn get_strk_rewards_claimed(self: @ContractState, user: ContractAddress) -> bool {
            self.strk_rewards_claimed.read(user)
        }

        /// Claims STRK rewards for eligible users
        fn claim_strk_rewards(ref self: ContractState) {
            let caller = get_caller_address();

            //FIRST Confirm is user is registred
            assert(
                self.registered_users.read(caller), 
                USER_NOT_REGISTERED
            );

            //check if user has not already received the funds
            assert(
                !self.strk_rewards_claimed.read(caller),
                REWARDS_ALREADY_CLAIMED
            );

            

            assert(
                self.user_nft_counts.read(caller) >= NFT_THRESHOLD_FOR_REWARD,
                NEED_FIVE_NFTS
            );


            self.strk_rewards_claimed.write(caller, true);
            
            // Transfer STRK tokens
            let strk_token = IERC20Dispatcher { 
                contract_address: self.strk_token.read() 
            };
            assert(
                strk_token.transfer(caller, STRK_REWARD_AMOUNT), 
                STRK_TRANSFER_FAILED
            );
            
            self.emit(Event::STRKRewardsClaimed(STRKRewardsClaimed {
                user: caller,
                amount: STRK_REWARD_AMOUNT
            }));
        }

        /// Gets user submissions
        fn get_user_submissions(self: @ContractState, user: ContractAddress) -> felt252 {
            self.user_submissions.read(user)
        }
    }
}