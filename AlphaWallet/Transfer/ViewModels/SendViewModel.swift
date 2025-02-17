// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import BigInt

struct SendViewModel {
    private let session: WalletSession
    private let storage: TokensDataStore

    let transactionType: TransactionType

    init(transactionType: TransactionType, session: WalletSession, storage: TokensDataStore) {
        self.transactionType = transactionType
        self.session = session
        self.storage = storage
    }

    var destinationAddress: AlphaWallet.Address {
        return transactionType.contract
    }

    var backgroundColor: UIColor {
        return Colors.appBackground
    }

    var token: TokenObject? {
        switch transactionType {
        case .nativeCryptocurrency:
            return nil
        case .ERC20Token(let token, _, _):
            return token
        case .ERC875Token(let token):
            return token
        case .ERC875TokenOrder(let token):
            return token
        case .ERC721Token(let token):
            return token
        case .ERC721ForTicketToken(let token):
            return token
        case .ERC1155Token(let token):
            return token
        case .dapp, .tokenScript, .claimPaidErc875MagicLink:
            return nil
        }
    }

    var textFieldsLabelTextColor: UIColor {
        return Colors.appGrayLabel
    }
    var textFieldsLabelFont: UIFont {
        return Fonts.regular(size: 10)
    }

    var recipientLabelFont: UIFont {
        return Fonts.regular(size: 13)
    }

    var recepientLabelTextColor: UIColor {
        return R.color.dove()!
    }

    var recipientsAddress: String {
        return R.string.localizable.sendRecipientsAddress()
    }

    var selectCurrencyButtonHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency:
            guard let ticker = session.balanceCoordinator.coinTicker(transactionType.addressAndRPCServer), ticker.price_usd > 0 else {
                return true
            } 
            return false
        case .ERC20Token, .ERC875Token, .ERC875TokenOrder, .ERC721Token, .ERC721ForTicketToken, .ERC1155Token, .dapp, .tokenScript, .claimPaidErc875MagicLink:
            return true
        }
    }

    var currencyButtonHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency, .ERC20Token:
            return false
        case .ERC875Token, .ERC875TokenOrder, .ERC721Token, .ERC721ForTicketToken, .ERC1155Token, .dapp, .tokenScript, .claimPaidErc875MagicLink:
            return true
        }
    }

    var availableLabelText: String? {
        switch transactionType {
        case .nativeCryptocurrency:
            return R.string.localizable.sendAvailable(session.balanceCoordinator.ethBalanceViewModel.amountShort)
        case .ERC20Token(let token, _, _):
            let value = EtherNumberFormatter.short.string(from: token.valueBigInt, decimals: token.decimals)
            return R.string.localizable.sendAvailable("\(value) \(transactionType.symbol)")
        case .dapp, .ERC721ForTicketToken, .ERC721Token, .ERC875Token, .ERC875TokenOrder, .ERC1155Token, .tokenScript, .claimPaidErc875MagicLink:
            break
        }

        return nil
    }

    var availableTextHidden: Bool {
        switch transactionType {
        case .nativeCryptocurrency:
            return false
        case .ERC20Token(let token, _, _):
            let tokenBalance = storage.token(forContract: token.contractAddress)?.valueBigInt
            return tokenBalance == nil
        case .dapp, .ERC721ForTicketToken, .ERC721Token, .ERC875Token, .ERC1155Token, .ERC875TokenOrder, .tokenScript, .claimPaidErc875MagicLink:
            break
        }
        return true
    }

    func validatedAmount(value amountString: String, checkIfGreaterThanZero: Bool = true) -> BigInt? {
        let parsedValue: BigInt? = {
            switch transactionType {
            case .nativeCryptocurrency, .dapp, .tokenScript, .claimPaidErc875MagicLink:
                return EtherNumberFormatter.full.number(from: amountString, units: .ether)
            case .ERC20Token(let token, _, _):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .ERC875Token(let token):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .ERC875TokenOrder(let token):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .ERC721Token(let token):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .ERC721ForTicketToken(let token):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            case .ERC1155Token(let token):
                return EtherNumberFormatter.full.number(from: amountString, decimals: token.decimals)
            }
        }()

        guard let value = parsedValue, checkIfGreaterThanZero ? value > 0 : true else {
            return nil
        }

        switch transactionType {
        case .nativeCryptocurrency:
            if session.balanceCoordinator.ethBalanceViewModel.value < value {
                return nil
            }
        case .ERC20Token(let token, _, _):
            if let tokenBalance = storage.token(forContract: token.contractAddress)?.valueBigInt, tokenBalance < value {
                return nil
            }
        case .dapp, .ERC721ForTicketToken, .ERC721Token, .ERC875Token, .ERC1155Token, .ERC875TokenOrder, .tokenScript, .claimPaidErc875MagicLink:
            break
        }

        return value

    }
}
