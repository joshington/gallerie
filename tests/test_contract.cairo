use core::array::ArrayTrait;

use core::byte_array::ByteArray;
use core::traits::TryInto;
use core::result::ResultTrait;
use core::serde::Serde;
use starknet::ContractAddress;
use snforge_std::{declare, ContractClassTrait,start_mock_call, stop_mock_call};

use gallerie::IGallerieDispatcher;
use gallerie::IGallerieDispatcherTrait;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

fn deploy_contract(name: felt252) -> (ContractAddress, ContractAddress) {
    // Deploy mock STRK token first
    let mock_strk = declare('MockERC20');
    let mock_strk_address = mock_strk.deploy(@array![]).unwrap();

    // Deploy Gallerie contract
    let contract = declare(name);
    let constructor_args = array![mock_strk_address.into()];
    let contract_address = contract.deploy(@constructor_args).unwrap();
    
    (contract_address, mock_strk_address)
}

#[test]
fn test_register_user() {
    let (contract_address, _) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Register user
    dispatcher.register_user();

    // Verify registration
    let user = starknet::get_caller_address();
    assert(dispatcher.get_user_nft_count(user) == 0, 'Invalid NFT count');
    assert(!dispatcher.get_strk_rewards_claimed(user), 'Invalid rewards status');
}

#[test]
#[should_panic(expected: ('USER_ALREADY_REGISTERED',))]
fn test_register_user_twice() {
    let (contract_address, _) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Register user twice
    dispatcher.register_user();
    dispatcher.register_user(); // Should panic
}

#[test]
fn test_submit_photo_grid() {
    let (contract_address, _) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Register user first
    dispatcher.register_user();

    // Submit a photo grid
    let grid_hash: felt252 = 123;
    let grid_uri = ByteArray { data: array![], pending_word: 0, pending_word_len: 0 };
    dispatcher.submit_photo_grid(grid_hash, grid_uri);

    // Verify submission
    let user = starknet::get_caller_address();
    assert(dispatcher.get_user_nft_count(user) == 1, 'Invalid NFT count');
    assert(dispatcher.get_user_submissions(user) == grid_hash, 'Invalid grid hash');
}

#[test]
#[should_panic(expected: ('USER_NOT_REGISTERED',))]
fn test_submit_without_registration() {
    let (contract_address, _) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Try to submit without registration
    let grid_hash: felt252 = 123;
    let grid_uri = ByteArray { data: array![], pending_word: 0, pending_word_len: 0 };
    dispatcher.submit_photo_grid(grid_hash, grid_uri); // Should panic
}

#[test]
fn test_strk_rewards() {
    let (contract_address, mock_strk_address) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Mock STRK transfer to always return true
    let mock_value: felt252 = 1;
    start_mock_call(mock_strk_address, 'transfer', @array![mock_value]);

    // Register user
    dispatcher.register_user();

    // Submit 5 photo grids
    let mut i: u8 = 0;
    loop {
        if i >= 5 {
            break;
        }
        let grid_hash: felt252 = i.into();
        let mut data = ArrayTrait::new();
        data.append('ipfs://test');
        let grid_uri = ByteArray { data, pending_word: 0, pending_word_len: 0 };
        dispatcher.submit_photo_grid(grid_hash, grid_uri);
        i += 1;
    };

    // Verify NFT count
    let user = starknet::get_caller_address();
    assert(dispatcher.get_user_nft_count(user) == 5, 'Invalid NFT count');

    // Claim rewards
    dispatcher.claim_strk_rewards();

    // Verify rewards claimed
    assert(dispatcher.get_strk_rewards_claimed(user), 'Rewards not claimed');

    stop_mock_call(mock_strk_address, 'transfer');
}

#[test]
#[should_panic(expected: ('NEED_FIVE_NFTS',))]
fn test_claim_rewards_too_early() {
    let (contract_address, _) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Register user
    dispatcher.register_user();

    // Submit only 4 photo grids
    let mut i: u8 = 0;
    loop {
        if i >= 4 {
            break;
        }
        let grid_hash: felt252 = i.into();
        let grid_uri: ByteArray = 'ipfs://test'.try_into().unwrap();
        dispatcher.submit_photo_grid(grid_hash, grid_uri);
        i += 1;
    };

    // Try to claim rewards
    dispatcher.claim_strk_rewards(); // Should panic
}

#[test]
#[should_panic(expected: ('REWARDS_ALREADY_CLAIMED',))]
fn test_claim_rewards_twice() {
    let (contract_address, mock_strk_address) = deploy_contract('Gallerie');
    let dispatcher = IGallerieDispatcher { contract_address };

    // Mock STRK transfer to always return true
    let mock_value: felt252 = 1;
    start_mock_call(mock_strk_address, 'transfer', @array![mock_value]);

    // Register and submit 5 grids
    dispatcher.register_user();
    let mut i: u8 = 0;
    loop {
        if i >= 5 {
            break;
        }
        let grid_hash: felt252 = i.into();
        let grid_uri =  ByteArray::from('ipfs://test');
        dispatcher.submit_photo_grid(grid_hash, grid_uri);
        i += 1;
    };

    // Claim rewards twice
    dispatcher.claim_strk_rewards();
    dispatcher.claim_strk_rewards(); // Should panic

    stop_mock_call(mock_strk_address, 'transfer');
}
