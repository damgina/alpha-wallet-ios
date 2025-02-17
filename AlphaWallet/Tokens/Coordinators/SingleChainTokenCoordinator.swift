// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import Alamofire
import BigInt
import RealmSwift
import PromiseKit
import Result

struct NoTokenError: LocalizedError {
    var errorDescription: String? {
        return R.string.localizable.aWalletNoTokens()
    }
}

protocol SingleChainTokenCoordinatorDelegate: class, CanOpenURL {
    func tokensDidChange(inCoordinator coordinator: SingleChainTokenCoordinator)
    func didTapSwap(forTransactionType transactionType: TransactionType, service: SwapTokenURLProviderType, in coordinator: SingleChainTokenCoordinator)
    func shouldOpen(url: URL, shouldSwitchServer: Bool, forTransactionType transactionType: TransactionType, in coordinator: SingleChainTokenCoordinator)
    func didPress(for type: PaymentFlow, inViewController viewController: UIViewController, in coordinator: SingleChainTokenCoordinator)
    func didTap(transaction: TransactionInstance, inViewController viewController: UIViewController, in coordinator: SingleChainTokenCoordinator)
    func didTap(activity: Activity, inViewController viewController: UIViewController, in coordinator: SingleChainTokenCoordinator)
    func didPostTokenScriptTransaction(_ transaction: SentTransaction, in coordinator: SingleChainTokenCoordinator)
}

// swiftlint:disable type_body_length
class SingleChainTokenCoordinator: Coordinator {
    private let keystore: Keystore
    private let storage: TokensDataStore
    private let cryptoPrice: Subscribable<Double>
    private let assetDefinitionStore: AssetDefinitionStore
    private let eventsDataStore: EventsDataStoreProtocol
    private let analyticsCoordinator: AnalyticsCoordinator
    private let autoDetectTransactedTokensQueue: OperationQueue
    private let autoDetectTokensQueue: OperationQueue
    private var isAutoDetectingTransactedTokens = false
    private var isAutoDetectingTokens = false
    private let tokenActionsProvider: TokenActionsProvider
    private let transactionsStorage: TransactionsStorage
    private let coinTickersFetcher: CoinTickersFetcherType
    private let activitiesService: ActivitiesServiceType
    let session: WalletSession
    weak var delegate: SingleChainTokenCoordinatorDelegate?
    var coordinators: [Coordinator] = []
    private lazy var tokenProvider: TokenProviderType = TokenProvider(account: storage.account, server: storage.server)

    var server: RPCServer {
        session.server
    }
    private let queue = DispatchQueue(label: "com.SingleChainTokenCoordinator.updateQueue")

    init(
            session: WalletSession,
            keystore: Keystore,
            tokensStorage: TokensDataStore,
            ethPrice: Subscribable<Double>,
            assetDefinitionStore: AssetDefinitionStore,
            eventsDataStore: EventsDataStoreProtocol,
            analyticsCoordinator: AnalyticsCoordinator,
            withAutoDetectTransactedTokensQueue autoDetectTransactedTokensQueue: OperationQueue,
            withAutoDetectTokensQueue autoDetectTokensQueue: OperationQueue,
            tokenActionsProvider: TokenActionsProvider,
            transactionsStorage: TransactionsStorage,
            coinTickersFetcher: CoinTickersFetcherType,
            activitiesService: ActivitiesServiceType
    ) {
        self.session = session
        self.keystore = keystore
        self.storage = tokensStorage
        self.cryptoPrice = ethPrice
        self.assetDefinitionStore = assetDefinitionStore
        self.eventsDataStore = eventsDataStore
        self.analyticsCoordinator = analyticsCoordinator
        self.autoDetectTransactedTokensQueue = autoDetectTransactedTokensQueue
        self.autoDetectTokensQueue = autoDetectTokensQueue
        self.tokenActionsProvider = tokenActionsProvider
        self.transactionsStorage = transactionsStorage
        self.coinTickersFetcher = coinTickersFetcher
        self.activitiesService = activitiesService
    }

    func start() {
        //Since this is called at launch, we don't want it to block launching
        queue.async { [weak self] in
            self?.autoDetectTransactedTokens()
            self?.autoDetectPartnerTokens()
        }
    }

    func isServer(_ server: RPCServer) -> Bool {
        return session.server == server
    }

    ///Implementation: We refresh once only, after all the auto detected tokens' data have been pulled because each refresh pulls every tokens' (including those that already exist before the this auto detection) price as well as balance, placing heavy and redundant load on the device. After a timeout, we refresh once just in case it took too long, so user at least gets the chance to see some auto detected tokens
    private func autoDetectTransactedTokens() {
        //TODO we don't auto detect tokens if we are running tests. Maybe better to move this into app delegate's application(_:didFinishLaunchingWithOptions:)
        guard !isRunningTests() else { return }
        guard !session.config.isAutoFetchingDisabled else { return }
        guard !isAutoDetectingTransactedTokens else { return }

        isAutoDetectingTransactedTokens = true
        let operation = AutoDetectTransactedTokensOperation(forServer: server, coordinator: self, wallet: keystore.currentWallet.address)
        autoDetectTransactedTokensQueue.addOperation(operation)
    }

    private func contractsForTransactedTokens(detectedContracts: [AlphaWallet.Address], storage: TokensDataStore) -> Promise<[AlphaWallet.Address]> {
        return Promise { seal in
            DispatchQueue.main.async {
                let alreadyAddedContracts = storage.enabledObjectAddresses
                let deletedContracts = storage.deletedContracts.map { $0.contractAddress }
                let hiddenContracts = storage.hiddenContracts.map { $0.contractAddress }
                let delegateContracts = storage.delegateContracts.map { $0.contractAddress }
                let contractsToAdd = detectedContracts - alreadyAddedContracts - deletedContracts - hiddenContracts - delegateContracts

                seal.fulfill(contractsToAdd)
            }
        }
    }

    private func autoDetectTransactedTokensImpl(wallet: AlphaWallet.Address, erc20: Bool) -> Promise<Void> {
        let startBlock: Int?
        if erc20 {
            startBlock = Config.getLastFetchedAutoDetectedTransactedTokenErc20BlockNumber(server, wallet: wallet).flatMap { $0 + 1 }
        } else {
            startBlock = Config.getLastFetchedAutoDetectedTransactedTokenNonErc20BlockNumber(server, wallet: wallet).flatMap { $0 + 1 }
        }

        return firstly {
            GetContractInteractions(queue: queue).getContractList(address: wallet, server: server, startBlock: startBlock, erc20: erc20)
        }.then(on: queue) { [weak self] contracts, maxBlockNumber -> Promise<Bool> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

            if let maxBlockNumber = maxBlockNumber {
                if erc20 {
                    Config.setLastFetchedAutoDetectedTransactedTokenErc20BlockNumber(maxBlockNumber, server: strongSelf.server, wallet: wallet)
                } else {
                    Config.setLastFetchedAutoDetectedTransactedTokenNonErc20BlockNumber(maxBlockNumber, server: strongSelf.server, wallet: wallet)
                }
            }
            let currentAddress = strongSelf.keystore.currentWallet.address
            guard currentAddress.sameContract(as: wallet) else { return .init(error: PMKError.cancelled) }
            let detectedContracts = contracts

            return strongSelf.contractsForTransactedTokens(detectedContracts: detectedContracts, storage: strongSelf.storage).then(on: strongSelf.queue, { contractsToAdd -> Promise<Bool> in
                let promises = contractsToAdd.compactMap { each -> Promise<BatchObject> in
                    strongSelf.fetchBatchObjectFromContractData(for: each, server: strongSelf.server, storage: strongSelf.storage)
                }

                return when(resolved: promises).then(on: .main, { values -> Promise<Bool> in
                    let values = values.compactMap { $0.optionalValue }.filter { $0.nonEmptyAction }
                    strongSelf.storage.addBatchObjectsOperation(values: values)

                    return .value(!values.isEmpty)
                })
            })
        }.get(on: .main, { [weak self] didUpdateObjects in
            guard let strongSelf = self else { return }

            if didUpdateObjects {
                strongSelf.notifyTokensDidChange()
            }
        }).asVoid()
    }

    private func notifyTokensDidChange() {
        //NOTE: as UI is going to get updated from realm notification not sure if we still need it here
        // delegate.flatMap { $0.tokensDidChange(inCoordinator: self) }
    }

    private func autoDetectPartnerTokens() {
        guard !session.config.isAutoFetchingDisabled else { return }
        switch server {
        case .main:
            autoDetectMainnetPartnerTokens()
        case .xDai:
            autoDetectXDaiPartnerTokens()
        case .rinkeby:
            autoDetectRinkebyPartnerTokens()
        case .kovan, .ropsten, .poa, .sokol, .classic, .callisto, .goerli, .artis_sigma1, .binance_smart_chain, .binance_smart_chain_testnet, .artis_tau1, .custom, .heco_testnet, .heco, .fantom, .fantom_testnet, .avalanche, .avalanche_testnet, .polygon, .mumbai_testnet, .optimistic, .optimisticKovan, .cronosTestnet:
            break
        }
    }

    private func autoDetectMainnetPartnerTokens() {
        autoDetectTokens(withContracts: Constants.partnerContracts)
    }

    private func autoDetectXDaiPartnerTokens() {
        autoDetectTokens(withContracts: Constants.ethDenverXDaiPartnerContracts)
    }

    private func autoDetectRinkebyPartnerTokens() {
        autoDetectTokens(withContracts: Constants.rinkebyPartnerContracts)
    }

    private func autoDetectTokens(withContracts contractsToDetect: [(name: String, contract: AlphaWallet.Address)]) {
        guard !isAutoDetectingTokens else { return }

        let address = keystore.currentWallet.address
        isAutoDetectingTokens = true
        let operation = AutoDetectTokensOperation(forServer: server, coordinator: self, wallet: address, tokens: contractsToDetect)
        autoDetectTokensQueue.addOperation(operation)
    }

    private func contractsToAutodetectTokens(withContracts contractsToDetect: [(name: String, contract: AlphaWallet.Address)], storage: TokensDataStore) -> Promise<[AlphaWallet.Address]> {
        return Promise { seal in
            DispatchQueue.main.async {
                let alreadyAddedContracts = storage.enabledObjectAddresses
                let deletedContracts = storage.deletedContracts.map { $0.contractAddress }
                let hiddenContracts = storage.hiddenContracts.map { $0.contractAddress }

                seal.fulfill(contractsToDetect.map { $0.contract } - alreadyAddedContracts - deletedContracts - hiddenContracts)
            }
        }
    }

    private func autoDetectTokensImpl(withContracts contractsToDetect: [(name: String, contract: AlphaWallet.Address)], server: RPCServer, completion: @escaping () -> Void) {
        let address = keystore.currentWallet.address
        contractsToAutodetectTokens(withContracts: contractsToDetect, storage: storage).map(on: queue, { contracts -> [Promise<SingleChainTokenCoordinator.BatchObject>] in
            contracts.map { [weak self] each -> Promise<BatchObject> in
                guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

                return strongSelf.tokenProvider.getTokenType(for: each).then { tokenType -> Promise<BatchObject> in
                    switch tokenType {
                    case .erc875:
                        //TODO long and very similar code below. Extract function
                        let balanceCoordinator = GetERC875BalanceCoordinator(forServer: server)
                        return balanceCoordinator.getERC875TokenBalance(for: address, contract: each).then { balance -> Promise<BatchObject> in
                            if balance.isEmpty {
                                return .value(.none)
                            } else {
                                return strongSelf.fetchBatchObjectFromContractData(for: each, server: server, storage: strongSelf.storage)
                            }
                        }.recover { _ -> Guarantee<BatchObject> in
                            return .value(.none)
                        }
                    case .erc20:
                        let balanceCoordinator = GetERC20BalanceCoordinator(forServer: server)
                        return balanceCoordinator.getBalance(for: address, contract: each).then { balance -> Promise<BatchObject> in
                            if balance > 0 {
                                return strongSelf.fetchBatchObjectFromContractData(for: each, server: server, storage: strongSelf.storage)
                            } else {
                                return .value(.none)
                            }
                        }.recover { _ -> Guarantee<BatchObject> in
                            return .value(.none)
                        }
                    case .erc721:
                        //Handled in PrivateBalanceFetcher.refreshBalanceForErc721Or1155Tokens()
                        return .value(.none)
                    case .erc721ForTickets:
                        //Handled in PrivateBalanceFetcher.refreshBalanceForNonErc721Or1155Tokens()
                        return .value(.none)
                    case .erc1155:
                        //Handled in PrivateBalanceFetcher.refreshBalanceForErc721Or1155Tokens()
                        return .value(.none)
                    case .nativeCryptocurrency:
                        return .value(.none)
                    }
                }
            }
        }).then(on: queue, { promises -> Promise<Bool> in
            return when(resolved: promises).then(on: .main, { [weak self] results -> Promise<Bool> in
                guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

                let values = results.compactMap { $0.optionalValue }.filter { $0.nonEmptyAction }

                strongSelf.storage.addBatchObjectsOperation(values: values)

                return .value(!values.isEmpty)
            })
        }).done(on: .main, { [weak self] didUpdate in
            guard let strongSelf = self else { return }

            if didUpdate {
                strongSelf.notifyTokensDidChange()
            }
        }).cauterize().finally(completion)
    }

    enum BatchObject {
        case ercToken(ERCToken)
        case tokenObject(TokenObject)
        case delegateContracts([DelegateContract])
        case deletedContracts([DeletedContract])
        case none

        var nonEmptyAction: Bool {
            switch self {
            case .none:
                return false
            case .ercToken, .tokenObject, .delegateContracts, .deletedContracts:
                return true
            }
        }
    }

    private func fetchBatchObjectFromContractData(for contract: AlphaWallet.Address, onlyIfThereIsABalance: Bool = false, server: RPCServer, storage: TokensDataStore) -> Promise <BatchObject> {
        return Promise { seal in
            fetchContractData(for: contract) { data in
                DispatchQueue.main.async {
                    switch data {
                    case .name, .symbol, .balance, .decimals:
                        break
                    case .nonFungibleTokenComplete(let name, let symbol, let balance, let tokenType):
                        guard !onlyIfThereIsABalance || (onlyIfThereIsABalance && !balance.isEmpty) else { break }
                        let token = ERCToken(
                                contract: contract,
                                server: server,
                                name: name,
                                symbol: symbol,
                                decimals: 0,
                                type: tokenType,
                                balance: balance
                        )

                        seal.fulfill(.ercToken(token))
                    case .fungibleTokenComplete(let name, let symbol, let decimals):
                        //We re-use the existing balance value to avoid the Wallets tab showing that token (if it already exist) as balance = 0 momentarily
                        storage.tokenPromise(forContract: contract).done { tokenObject in
                            let value = tokenObject?.value ?? "0"
                            guard !onlyIfThereIsABalance || (onlyIfThereIsABalance && !(value != "0")) else { return seal.fulfill(.none) }
                            let token = TokenObject(
                                    contract: contract,
                                    server: server,
                                    name: name,
                                    symbol: symbol,
                                    decimals: Int(decimals),
                                    value: value,
                                    type: .erc20
                            )
                            seal.fulfill(.tokenObject(token))
                        }.cauterize()
                    case .delegateTokenComplete:
                        seal.fulfill(.delegateContracts([DelegateContract(contractAddress: contract, server: server)]))
                    case .failed(let networkReachable):
                        if let networkReachable = networkReachable, networkReachable {
                            seal.fulfill(.deletedContracts([DeletedContract(contractAddress: contract, server: server)]))
                        } else {
                            seal.fulfill(.none)
                        }
                    }
                }
            }
        }
    }

    private func addToken(for contract: AlphaWallet.Address, onlyIfThereIsABalance: Bool = false, server: RPCServer, storage: TokensDataStore, completion: @escaping (TokenObject?) -> Void) {
        firstly {
            fetchBatchObjectFromContractData(for: contract, server: server, storage: storage)
        }.map(on: .main, { operation -> [TokenObject] in
            return storage.addBatchObjectsOperation(values: [operation])
        }).done(on: .main, { tokenObjects in
            completion(tokenObjects.first)
        }).catch(on: .main, { _ in
            completion(nil)
        })
    }

    //Adding a token may fail if we lose connectivity while fetching the contract details (e.g. name and balance). So we remove the contract from the hidden list (if it was there) so that the app has the chance to add it automatically upon auto detection at startup
    func addImportedToken(forContract contract: AlphaWallet.Address, onlyIfThereIsABalance: Bool = false) {
        firstly {
            delete(hiddenContract: contract)
        }.then { [weak self] _ -> Promise<TokenObject> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }
            return strongSelf.addImportedTokenPromise(forContract: contract, onlyIfThereIsABalance: onlyIfThereIsABalance)
        }.done { _ in

        }.cauterize()
    }

    //Adding a token may fail if we lose connectivity while fetching the contract details (e.g. name and balance). So we remove the contract from the hidden list (if it was there) so that the app has the chance to add it automatically upon auto detection at startup
    func addImportedTokenPromise(forContract contract: AlphaWallet.Address, onlyIfThereIsABalance: Bool = false) -> Promise<TokenObject> {
        struct ImportTokenError: Error { }

        return firstly {
            delete(hiddenContract: contract)
        }.then(on: .main, { _ -> Promise<TokenObject> in
            return Promise<TokenObject> { [weak self] seal in
                guard let strongSelf = self else { return seal.reject(PMKError.cancelled) }

                return strongSelf.addToken(for: contract, onlyIfThereIsABalance: onlyIfThereIsABalance, server: strongSelf.server, storage: strongSelf.storage) { tokenObject in
                    if let tokenObject = tokenObject {
                        seal.fulfill(tokenObject)
                    } else {
                        seal.reject(ImportTokenError())
                    }
                }
            }
        }).get(on: .main, { [weak self] _ in
            guard let strongSelf = self else { return }

            strongSelf.notifyTokensDidChange()
        })
    }

    private func delete(hiddenContract contract: AlphaWallet.Address) -> Promise<Void> {
        return Promise<Void> { seal in
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return seal.reject(PMKError.cancelled) }

                guard let hiddenContract = strongSelf.storage.hiddenContracts.first(where: { contract.sameContract(as: $0.contract) }) else { return seal.reject(PMKError.cancelled) }
                //TODO we need to make sure it's all uppercase?
                strongSelf.storage.delete(hiddenContracts: [hiddenContract])

                seal.fulfill(())
            }
        }
    }

    func fetchContractData(for address: AlphaWallet.Address, completion: @escaping (ContractData) -> Void) {
        ContractDataDetector(address: address, account: session.account, server: session.server, assetDefinitionStore: assetDefinitionStore).fetch(completion: completion)
    }

    func showTokenList(for type: PaymentFlow, token: TokenObject, navigationController: UINavigationController) {
        guard !token.nonZeroBalance.isEmpty else {
            navigationController.displayError(error: NoTokenError())
            return
        }

        switch token.type {
        case .erc1155:
            showTokensCardCollection(for: type, token: token, navigationController: navigationController)
        case .erc721:
            showTokenCard(for: type, token: token, navigationController: navigationController)
        case .nativeCryptocurrency, .erc20, .erc875, .erc721ForTickets:
            break
        }
    }

    private func showTokensCardCollection(for type: PaymentFlow, token: TokenObject, navigationController: UINavigationController) {
        let activitiesFilterStrategy: ActivitiesFilterStrategy = .erc20(contract: token.contractAddress)
        let activitiesService = self.activitiesService.copy(activitiesFilterStrategy: activitiesFilterStrategy, transactionsFilterStrategy: transactionsFilter(for: activitiesFilterStrategy, tokenObject: token))

        let tokensCardCoordinator = TokensCardCollectionCoordinator(
                session: session,
                navigationController: navigationController,
                keystore: keystore,
                tokensStorage: storage,
                ethPrice: cryptoPrice,
                token: token,
                assetDefinitionStore: assetDefinitionStore,
                eventsDataStore: eventsDataStore,
                analyticsCoordinator: analyticsCoordinator,
                activitiesService: activitiesService
        )

        addCoordinator(tokensCardCoordinator)
        //tokensCardCoordinator.delegate = self
        tokensCardCoordinator.start()
        tokensCardCoordinator.makeCoordinatorReadOnlyIfNotSupportedByOpenSeaERC1155(type: type)
    }

    private func showTokenCard(for type: PaymentFlow, token: TokenObject, navigationController: UINavigationController) {
        let tokensCardCoordinator = TokensCardCoordinator(
                session: session,
                navigationController: navigationController,
                keystore: keystore,
                tokensStorage: storage,
                ethPrice: cryptoPrice,
                token: token,
                assetDefinitionStore: assetDefinitionStore,
                eventsDataStore: eventsDataStore,
                analyticsCoordinator: analyticsCoordinator
        )

        addCoordinator(tokensCardCoordinator)
        tokensCardCoordinator.delegate = self
        tokensCardCoordinator.start()
        tokensCardCoordinator.makeCoordinatorReadOnlyIfNotSupportedByOpenSeaERC721(type: type)
    }

    private func transactionsFilter(for strategy: ActivitiesFilterStrategy, tokenObject: TokenObject) -> TransactionsFilterStrategy {
        let filter = FilterInSingleTransactionsStorage(transactionsStorage: transactionsStorage) { tx in
            return strategy.isRecentTransaction(transaction: tx)
        }

        return .filter(filter: filter, tokenObject: tokenObject)
    }

    func show(fungibleToken token: TokenObject, transactionType: TransactionType, navigationController: UINavigationController) {
        //NOTE: create half mutable copy of `activitiesService` to configure it for fetching activities for specific token
        let activitiesFilterStrategy = transactionType.activitiesFilterStrategy
        let activitiesService = self.activitiesService.copy(activitiesFilterStrategy: activitiesFilterStrategy, transactionsFilterStrategy: transactionsFilter(for: activitiesFilterStrategy, tokenObject: transactionType.tokenObject))
        let viewModel = TokenViewControllerViewModel(transactionType: transactionType, session: session, tokensStore: storage, assetDefinitionStore: assetDefinitionStore, tokenActionsProvider: tokenActionsProvider)
        let viewController = TokenViewController(session: session, tokensDataStore: storage, assetDefinition: assetDefinitionStore, transactionType: transactionType, analyticsCoordinator: analyticsCoordinator, token: token, viewModel: viewModel, activitiesService: activitiesService)
        viewController.delegate = self

        //NOTE: refactor later with subscribable coin ticker, and chart history
        coinTickersFetcher.fetchChartHistories(addressToRPCServerKey: token.addressAndRPCServer, force: false, periods: ChartHistoryPeriod.allCases).done { [weak self, weak viewController] history in
            guard let strongSelf = self, let viewController = viewController else { return }

            var viewModel = TokenViewControllerViewModel(transactionType: transactionType, session: strongSelf.session, tokensStore: strongSelf.storage, assetDefinitionStore: strongSelf.assetDefinitionStore, tokenActionsProvider: strongSelf.tokenActionsProvider)
            viewModel.chartHistory = history
            viewController.configure(viewModel: viewModel)
        }.catch { _ in
            //no-op
        }

        viewController.navigationItem.leftBarButtonItem = UIBarButtonItem.backBarButton(selectionClosure: {
            navigationController.popToRootViewController(animated: true)
        })

        navigationController.pushViewController(viewController, animated: true)

        refreshTokenViewControllerUponAssetDefinitionChanges(viewController, forTransactionType: transactionType)
    }

    private func refreshTokenViewControllerUponAssetDefinitionChanges(_ viewController: TokenViewController, forTransactionType transactionType: TransactionType) {
        assetDefinitionStore.subscribeToBodyChanges { [weak self, weak viewController] contract in
            guard let strongSelf = self, let viewController = viewController else { return }
            guard contract.sameContract(as: transactionType.contract) else { return }
            let viewModel = TokenViewControllerViewModel(transactionType: transactionType, session: strongSelf.session, tokensStore: strongSelf.storage, assetDefinitionStore: strongSelf.assetDefinitionStore, tokenActionsProvider: strongSelf.tokenActionsProvider)
            viewController.configure(viewModel: viewModel)
        }
        assetDefinitionStore.subscribeToSignatureChanges { [weak self, weak viewController] contract in
            guard let strongSelf = self, let viewController = viewController else { return }
            guard contract.sameContract(as: transactionType.contract) else { return }
            let viewModel = TokenViewControllerViewModel(transactionType: transactionType, session: strongSelf.session, tokensStore: strongSelf.storage, assetDefinitionStore: strongSelf.assetDefinitionStore, tokenActionsProvider: strongSelf.tokenActionsProvider)
            viewController.configure(viewModel: viewModel)
        }
    }

    func delete(token: TokenObject) {
        assetDefinitionStore.contractDeleted(token.contractAddress)
        storage.add(hiddenContracts: [HiddenContract(contractAddress: token.contractAddress, server: server)])
        storage.delete(tokens: [token])

        notifyTokensDidChange()
    }

    func updateOrderedTokens(with orderedTokens: [TokenObject]) {
        storage.updateOrderedTokens(with: orderedTokens)

        notifyTokensDidChange()
    }

    func mark(token: TokenObject, isHidden: Bool) {
        storage.update(token: token, action: .isHidden(isHidden))
    }

    func add(token: ERCToken) -> TokenObject {
        let tokenObject = storage.addCustom(token: token, shouldUpdateBalance: true)
        notifyTokensDidChange()

        return tokenObject
    }

    class AutoDetectTransactedTokensOperation: Operation {
        weak private var coordinator: SingleChainTokenCoordinator?
        private let wallet: AlphaWallet.Address
        override var isExecuting: Bool {
            return coordinator?.isAutoDetectingTransactedTokens ?? false
        }
        override var isFinished: Bool {
            return !isExecuting
        }
        override var isAsynchronous: Bool {
            return true
        }

        init(forServer server: RPCServer, coordinator: SingleChainTokenCoordinator, wallet: AlphaWallet.Address) {
            self.coordinator = coordinator
            self.wallet = wallet
            super.init()
            self.queuePriority = server.networkRequestsQueuePriority
        }

        override func main() {
            guard let strongCoordinator = coordinator else { return }
            let fetchErc20Tokens = strongCoordinator.autoDetectTransactedTokensImpl(wallet: wallet, erc20: true)
            let fetchNonErc20Tokens = strongCoordinator.autoDetectTransactedTokensImpl(wallet: wallet, erc20: false)

            when(resolved: [fetchErc20Tokens, fetchNonErc20Tokens]).done { [weak self] _ in
                guard let strongSelf = self else { return }

                strongSelf.willChangeValue(forKey: "isExecuting")
                strongSelf.willChangeValue(forKey: "isFinished")
                strongCoordinator.isAutoDetectingTransactedTokens = false
                strongSelf.didChangeValue(forKey: "isExecuting")
                strongSelf.didChangeValue(forKey: "isFinished")
            }.cauterize()
        }
    }

    class AutoDetectTokensOperation: Operation {
        weak private var coordinator: SingleChainTokenCoordinator?
        private let wallet: AlphaWallet.Address
        private let tokens: [(name: String, contract: AlphaWallet.Address)]
        override var isExecuting: Bool {
            return coordinator?.isAutoDetectingTokens ?? false
        }
        override var isFinished: Bool {
            return !isExecuting
        }
        override var isAsynchronous: Bool {
            return true
        }
        private let server: RPCServer

        init(forServer server: RPCServer, coordinator: SingleChainTokenCoordinator, wallet: AlphaWallet.Address, tokens: [(name: String, contract: AlphaWallet.Address)]) {
            self.coordinator = coordinator
            self.wallet = wallet
            self.tokens = tokens
            self.server = server
            super.init()
            self.queuePriority = server.networkRequestsQueuePriority
        }

        override func main() {
            coordinator?.autoDetectTokensImpl(withContracts: tokens, server: server) { [weak self, weak coordinator] in
                guard let strongSelf = self, let coordinator = coordinator else { return }

                strongSelf.willChangeValue(forKey: "isExecuting")
                strongSelf.willChangeValue(forKey: "isFinished")
                coordinator.isAutoDetectingTokens = false
                strongSelf.didChangeValue(forKey: "isExecuting")
                strongSelf.didChangeValue(forKey: "isFinished")
            }
        }
    }

    private func showTokenInstanceActionView(forAction action: TokenInstanceAction, fungibleTokenObject tokenObject: TokenObject, navigationController: UINavigationController) {
        //TODO id 1 for fungibles. Might come back to bite us?
        let hardcodedTokenIdForFungibles = BigUInt(1)
        let xmlHandler = XMLHandler(token: tokenObject, assetDefinitionStore: assetDefinitionStore)
        //TODO Event support, if/when designed for fungibles
        let values = xmlHandler.resolveAttributesBypassingCache(withTokenIdOrEvent: .tokenId(tokenId: hardcodedTokenIdForFungibles), server: self.session.server, account: self.session.account)
        let token = Token(tokenIdOrEvent: .tokenId(tokenId: hardcodedTokenIdForFungibles), tokenType: tokenObject.type, index: 0, name: tokenObject.name, symbol: tokenObject.symbol, status: .available, values: values)
        let tokenHolder = TokenHolder(tokens: [token], contractAddress: tokenObject.contractAddress, hasAssetDefinition: true)
        let vc = TokenInstanceActionViewController(analyticsCoordinator: analyticsCoordinator, tokenObject: tokenObject, tokenHolder: tokenHolder, tokensStorage: storage, assetDefinitionStore: assetDefinitionStore, action: action, session: session, keystore: keystore)
        vc.delegate = self
        vc.configure()
        vc.navigationItem.largeTitleDisplayMode = .never
        navigationController.pushViewController(vc, animated: true)
    }
}
// swiftlint:enable type_body_length

extension SingleChainTokenCoordinator: TokensCardCoordinatorDelegate {

    func didCancel(in coordinator: TokensCardCoordinator) {
        coordinator.navigationController.popToRootViewController(animated: true)
        removeCoordinator(coordinator)
    }

    func didPostTokenScriptTransaction(_ transaction: SentTransaction, in coordinator: TokensCardCoordinator) {
        delegate?.didPostTokenScriptTransaction(transaction, in: self)
    }
}

extension SingleChainTokenCoordinator: TokenViewControllerDelegate {

    func didTapSwap(forTransactionType transactionType: TransactionType, service: SwapTokenURLProviderType, inViewController viewController: TokenViewController) {
        delegate?.didTapSwap(forTransactionType: transactionType, service: service, in: self)
    }

    func shouldOpen(url: URL, shouldSwitchServer: Bool, forTransactionType transactionType: TransactionType, inViewController viewController: TokenViewController) {
        delegate?.shouldOpen(url: url, shouldSwitchServer: shouldSwitchServer, forTransactionType: transactionType, in: self)
    }

    func didTapSend(forTransactionType transactionType: TransactionType, inViewController viewController: TokenViewController) {
        delegate?.didPress(for: .send(type: transactionType), inViewController: viewController, in: self)
    }

    func didTapReceive(forTransactionType transactionType: TransactionType, inViewController viewController: TokenViewController) {
        delegate?.didPress(for: .request, inViewController: viewController, in: self)
    }

    func didTap(activity: Activity, inViewController viewController: TokenViewController) {
        delegate?.didTap(activity: activity, inViewController: viewController, in: self)
    }

    func didTap(transaction: TransactionInstance, inViewController viewController: TokenViewController) {
        delegate?.didTap(transaction: transaction, inViewController: viewController, in: self)
    }

    func didTap(action: TokenInstanceAction, transactionType: TransactionType, viewController: TokenViewController) {
        guard let navigationController = viewController.navigationController else { return }

        let token: TokenObject
        switch transactionType {
        case .ERC20Token(let erc20Token, _, _):
            token = erc20Token
        case .dapp, .ERC721Token, .ERC875Token, .ERC875TokenOrder, .ERC721ForTicketToken, .ERC1155Token, .tokenScript, .claimPaidErc875MagicLink:
            return
        case .nativeCryptocurrency:
            token = TokensDataStore.etherToken(forServer: server)
            showTokenInstanceActionView(forAction: action, fungibleTokenObject: token, navigationController: navigationController)
            return
        }
        switch action.type {
        case .tokenScript:
            showTokenInstanceActionView(forAction: action, fungibleTokenObject: token, navigationController: navigationController)
        case .erc20Send, .erc20Receive, .nftRedeem, .nftSell, .nonFungibleTransfer, .swap, .xDaiBridge, .buy:
            //Couldn't have reached here
            break
        }
    }
}

extension SingleChainTokenCoordinator: CanOpenURL {
    func didPressViewContractWebPage(forContract contract: AlphaWallet.Address, server: RPCServer, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(forContract: contract, server: server, in: viewController)
    }

    func didPressViewContractWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(url, in: viewController)
    }

    func didPressOpenWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressOpenWebPage(url, in: viewController)
    }
}

extension SingleChainTokenCoordinator: TransactionConfirmationCoordinatorDelegate {
    func coordinator(_ coordinator: TransactionConfirmationCoordinator, didFailTransaction error: AnyError) {
        //TODO improve error message. Several of this delegate func
        coordinator.navigationController.displayError(message: error.localizedDescription)
    }

    func didClose(in coordinator: TransactionConfirmationCoordinator) {
        removeCoordinator(coordinator)
    }

    func didSendTransaction(_ transaction: SentTransaction, inCoordinator coordinator: TransactionConfirmationCoordinator) {
        //no-op
    }

    func didFinish(_ result: ConfirmResult, in coordinator: TransactionConfirmationCoordinator) {
        coordinator.close { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.removeCoordinator(coordinator)

            let coordinator = TransactionInProgressCoordinator(presentingViewController: coordinator.presentingViewController)
            coordinator.delegate = strongSelf
            strongSelf.addCoordinator(coordinator)

            coordinator.start()
        }
    }
}

extension SingleChainTokenCoordinator: TokenInstanceActionViewControllerDelegate {
    func confirmTransactionSelected(in viewController: TokenInstanceActionViewController, tokenObject: TokenObject, contract: AlphaWallet.Address, tokenId: TokenId, values: [AttributeId: AssetInternalValue], localRefs: [AttributeId: AssetInternalValue], server: RPCServer, session: WalletSession, keystore: Keystore, transactionFunction: FunctionOrigin) {
        guard let navigationController = viewController.navigationController else { return }

        switch transactionFunction.makeUnConfirmedTransaction(withTokenObject: tokenObject, tokenId: tokenId, attributeAndValues: values, localRefs: localRefs, server: server, session: session) {
        case .success((let transaction, let functionCallMetaData)):
            let coordinator = TransactionConfirmationCoordinator(presentingViewController: navigationController, session: session, transaction: transaction, configuration: .tokenScriptTransaction(confirmType: .signThenSend, contract: contract, keystore: keystore, functionCallMetaData: functionCallMetaData, ethPrice: cryptoPrice), analyticsCoordinator: analyticsCoordinator)
            coordinator.delegate = self
            addCoordinator(coordinator)
            coordinator.start(fromSource: .tokenScript)
        case .failure:
            //TODO throw an error
            break
        }
    }

    func didPressViewRedemptionInfo(in viewController: TokenInstanceActionViewController) {
        //TODO: do nothing. We can probably even remove show redemption info?
    }

    func shouldCloseFlow(inViewController viewController: TokenInstanceActionViewController) {
        viewController.navigationController?.popViewController(animated: true)
    }
}

extension SingleChainTokenCoordinator: TransactionInProgressCoordinatorDelegate {

    func transactionInProgressDidDismiss(in coordinator: TransactionInProgressCoordinator) {
        removeCoordinator(coordinator)
    }
}
