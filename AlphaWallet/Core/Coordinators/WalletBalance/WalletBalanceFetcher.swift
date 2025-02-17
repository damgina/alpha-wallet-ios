//
//  WalletBalanceFetcherType.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 28.05.2021.
//

import UIKit
import RealmSwift
import BigInt
import PromiseKit

protocol WalletBalanceFetcherDelegate: AnyObject {
    func didAddToken(in fetcher: WalletBalanceFetcherType)
    func didUpdate(in fetcher: WalletBalanceFetcherType)
}

protocol WalletBalanceFetcherType: AnyObject {
    var tokenObjects: [Activity.AssignedToken] { get }
    var balance: WalletBalance { get }
    var subscribableWalletBalance: Subscribable<WalletBalance> { get }

    var isRunning: Bool { get }

    func subscribableTokenBalance(addressAndRPCServer: AddressAndRPCServer) -> Subscribable<BalanceBaseViewModel>
    func removeSubscribableTokenBalance(for addressAndRPCServer: AddressAndRPCServer)

    func start()
    func stop()
    func update(servers: [RPCServer])
    func refreshEthBalance()
    func refreshBalance()
    func transactionsStorage(server: RPCServer) -> TransactionsStorage
    func tokensDatastore(server: RPCServer) -> TokensDataStore
}
typealias WalletBalanceFetcherSubServices = (tokensDataStore: TokensDataStore, balanceFetcher: PrivateBalanceFetcherType, transactionsStorage: TransactionsStorage)

class WalletBalanceFetcher: NSObject, WalletBalanceFetcherType {
    private static let updateBalanceInterval: TimeInterval = 60
    private var timer: Timer?
    private let wallet: Wallet
    private let assetDefinitionStore: AssetDefinitionStore
    private (set) lazy var subscribableWalletBalance: Subscribable<WalletBalance> = .init(balance)
    private var services: ServerDictionary<WalletBalanceFetcherSubServices> = .init()

    var tokenObjects: [Activity.AssignedToken] {
        services.flatMap { $0.value.tokensDataStore.tokenObjects }
    }

    private let queue: DispatchQueue
    private var cache: ThreadSafeDictionary<AddressAndRPCServer, (NotificationToken, Subscribable<BalanceBaseViewModel>)> = .init()
    private let coinTickersFetcher: CoinTickersFetcherType

    weak var delegate: WalletBalanceFetcherDelegate?

    private lazy var realm = Wallet.functional.realm(forAccount: wallet)

    required init(wallet: Wallet, servers: [RPCServer], assetDefinitionStore: AssetDefinitionStore, queue: DispatchQueue, coinTickersFetcher: CoinTickersFetcherType) {
        self.wallet = wallet
        self.assetDefinitionStore = assetDefinitionStore
        self.queue = queue
        self.coinTickersFetcher = coinTickersFetcher

        super.init()

        for each in servers {
            let transactionsStorage = TransactionsStorage(realm: realm, server: each, delegate: nil)
            let tokensDatastore = TokensDataStore(realm: realm, account: wallet, server: each)
            let balanceFetcher = PrivateBalanceFetcher(account: wallet, tokensDatastore: tokensDatastore, server: each, assetDefinitionStore: assetDefinitionStore, queue: queue)
            balanceFetcher.erc721TokenIdsFetcher = transactionsStorage
            balanceFetcher.delegate = self

            self.services[each] = (tokensDatastore, balanceFetcher, transactionsStorage)
        }

        coinTickersFetcher.tickersSubscribable.subscribe { [weak self] _ in
            guard let strongSelf = self else { return }

            strongSelf.queue.async {
                strongSelf.notifyUpdateBalance()
                strongSelf.notifyUpdateTokenBalancesSubscribers()
            }
        }
    }

    func transactionsStorage(server: RPCServer) -> TransactionsStorage {
        services[server].transactionsStorage
    }

    func tokensDatastore(server: RPCServer) -> TokensDataStore {
        services[server].tokensDataStore
    }

    func update(servers: [RPCServer]) {
        for each in servers {
            if services[safe: each] != nil {
                //no-op
            } else {
                let transactionsStorage = TransactionsStorage(realm: realm, server: each, delegate: nil)
                let tokensDatastore = TokensDataStore(realm: realm, account: wallet, server: each)
                let balanceFetcher = PrivateBalanceFetcher(account: wallet, tokensDatastore: tokensDatastore, server: each, assetDefinitionStore: assetDefinitionStore, queue: queue)
                balanceFetcher.erc721TokenIdsFetcher = transactionsStorage
                balanceFetcher.delegate = self

                services[each] = (tokensDatastore, balanceFetcher, transactionsStorage)
            }
        }

        let delatedServers = services.filter { !servers.contains($0.key) }.map { $0.key }
        for each in delatedServers {
            services.remove(at: each)
        }
    }

    private func notifyUpdateTokenBalancesSubscribers() {
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }

            for (key, each) in strongSelf.cache.values {
                guard let service = strongSelf.services[safe: key.server] else { continue }
                guard let tokenObject = service.tokensDataStore.token(forContract: key.address) else { continue }

                each.1.value = strongSelf.balanceViewModel(key: tokenObject)
            }
        }
    }

    private func notifyUpdateBalance() {
        Promise<WalletBalance> { seal in
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return seal.reject(PMKError.cancelled) }
                let value = strongSelf.balance

                seal.fulfill(value)
            }
        }.get(on: .main, { [weak self] balance in
            self?.subscribableWalletBalance.value = balance
        }).done(on: queue, { [weak self] _ in
            guard let strongSelf = self else { return }

            strongSelf.delegate.flatMap { $0.didUpdate(in: strongSelf) }
        }).cauterize()
    }

    private func balanceViewModel(key tokenObject: TokenObject) -> BalanceBaseViewModel? {
        let ticker = coinTickersFetcher.tickers[tokenObject.addressAndRPCServer]

        switch tokenObject.type {
        case .nativeCryptocurrency:
            let balance = Balance(value: BigInt(tokenObject.value, radix: 10) ?? BigInt(0))
            return NativecryptoBalanceViewModel(server: tokenObject.server, balance: balance, ticker: ticker)
        case .erc20:
            let balance = ERC20Balance(tokenObject: tokenObject)
            return ERC20BalanceViewModel(server: tokenObject.server, balance: balance, ticker: ticker)
        case .erc875, .erc721, .erc721ForTickets, .erc1155:
            return nil
        }
    }

    func removeSubscribableTokenBalance(for addressAndRPCServer: AddressAndRPCServer) {
        if let value = cache[addressAndRPCServer] {
            value.0.invalidate()
            value.1.unsubscribeAll()

            cache[addressAndRPCServer] = .none
        }
    }

    func subscribableTokenBalance(addressAndRPCServer: AddressAndRPCServer) -> Subscribable<BalanceBaseViewModel> {
        guard let services = services[safe: addressAndRPCServer.server] else { return .init(nil) }

        guard let tokenObject = services.tokensDataStore.token(forContract: addressAndRPCServer.address) else {
            return .init(nil)
        }

        if let value = cache[addressAndRPCServer] {
            return value.1
        } else {
            let subscribable = Subscribable<BalanceBaseViewModel>(nil)

            let observation = tokenObject.observe(on: queue) { [weak self] change in
                guard let strongSelf = self else { return }

                switch change {
                case .change(let object, let properties):
                    if let tokenObject = object as? TokenObject, properties.isBalanceUpdate {
                        let balance = strongSelf.balanceViewModel(key: tokenObject)
                        subscribable.value = balance
                    }

                case .deleted, .error:
                    break
                }
            }

            cache[addressAndRPCServer] = (observation, subscribable)
            let balance = balanceViewModel(key: tokenObject)

            queue.async {
                subscribable.value = balance
            }

            return subscribable
        }
    }

    var balance: WalletBalance {
        let tokenObjects = services.compactMap { $0.value.0.enabledObject }.flatMap { $0 }.map { Activity.AssignedToken(tokenObject: $0) }
        var balances = Set<Activity.AssignedToken>()

        for var tokenObject in tokenObjects {
            tokenObject.ticker = coinTickersFetcher.tickers[tokenObject.addressAndRPCServer]

            balances.insert(tokenObject)
        }

        return .init(wallet: wallet, values: balances)
    }

    var isRunning: Bool {
        if let timer = timer {
            return timer.isValid
        } else {
            return false
        }
    }

    func start() {
        timedCallForBalanceRefresh()

        timer = Timer.scheduledTimer(withTimeInterval: Self.updateBalanceInterval, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }

            strongSelf.queue.async {
                strongSelf.timedCallForBalanceRefresh()
            }
        }
    }

    private func timedCallForBalanceRefresh() {
        for each in services {
            each.value.1.refreshBalance(updatePolicy: .all, force: false)
        }
    }

    func refreshEthBalance() {
        for each in services {
            each.value.1.refreshBalance(updatePolicy: .eth, force: true)
        }
    }

    func refreshBalance() {
        for each in services {
            each.value.1.refreshBalance(updatePolicy: .ercTokens, force: true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

extension WalletBalanceFetcher: PrivateTokensDataStoreDelegate {

    func didAddToken(in tokensDataStore: PrivateBalanceFetcher) {
        delegate?.didAddToken(in: self)
    }

    func didUpdate(in tokensDataStore: PrivateBalanceFetcher) {
        notifyUpdateBalance()
    }
}

fileprivate extension Array where Element == PropertyChange {
    var isBalanceUpdate: Bool {
        contains(where: { $0.name == "value" || $0.name == "balance" })
    }
}
