//
//  AppCoordinator.swift
//  ConcordiumWallet
//
//  Created by Concordium on 13/03/2020.
//  Copyright © 2020 concordium. All rights reserved.
//

import Combine
import Foundation
import UIKit

class AppCoordinator: NSObject, Coordinator, ShowAlert, RequestPasswordDelegate {
    var childCoordinators = [Coordinator]()

    var navigationController: UINavigationController
    let defaultProvider = ServicesProvider.defaultProvider()
    
    private var accountsCoordinator: AccountsCoordinator?
    private var needsAppCheck = true
    private var cancellables: [AnyCancellable] = []
    private var sanityChecker: SanityChecker
    override init() {
        navigationController = TransparentNavigationController()
        sanityChecker = SanityChecker(mobileWallet: defaultProvider.mobileWallet(), storageManager: defaultProvider.storageManager())
        super.init()
        sanityChecker.coordinator = self
        sanityChecker.errorDisplayer = self
    }

    func start() {
        if isNewAppInstall() {
            clearAppDataFromPreviousInstall()
        }

        AppSettings.hasRunBefore = true
        showLogin()
    }

    private func isNewAppInstall() -> Bool {
        return !AppSettings.hasRunBefore
    }

    private func clearAppDataFromPreviousInstall() {
        let keychain = defaultProvider.keychainWrapper()
        _ = keychain.deleteKeychainItem(withKey: KeychainKeys.password.rawValue)
        _ = keychain.deleteKeychainItem(withKey: KeychainKeys.loginPassword.rawValue)
        try? defaultProvider.seedMobileWallet().removeSeed()
    }

    private func showLogin() {
        let loginCoordinator = LoginCoordinator(navigationController: navigationController,
                                                parentCoordinator: self,
                                                dependencyProvider: defaultProvider)
        childCoordinators.append(loginCoordinator)
        loginCoordinator.start()
    }

    func showMainTabbar() {
        navigationController.setupBaseNavigationControllerStyle()
        
        accountsCoordinator = AccountsCoordinator(
            navigationController: self.navigationController,
            dependencyProvider: defaultProvider,
            appSettingsDelegate: self,
            accountsPresenterDelegate: self
        )
        // accountsCoordinator?.delegate = self
        accountsCoordinator?.start()
        
        sanityChecker.showValidateIdentitiesAlert(report: SanityChecker.lastSanityReport, mode: .automatic, completion: {
            self.showDelegationWarningIfNeeded()
        })
    }

    private func showDelegationWarningIfNeeded() {
        defaultProvider
            .storageManager()
            .getAccounts()
            .publisher
            .flatMap { account -> AnyPublisher<AccountDataType, Never> in
                guard let poolId = account.delegation?.delegationTargetBakerID else {
                    return .empty()
                }

                return self.defaultProvider
                    .stakeService()
                    .getBakerPool(bakerId: poolId)
                    .filter { $0.bakerStakePendingChange.pendingChangeType == "RemovePool" }
                    .map { _ in account }
                    .catch { _ in AnyPublisher.empty() }
                    .eraseToAnyPublisher()
            }
            .collect()
            .sink { accounts in
                guard !accounts.isEmpty else {
                    return
                }

                let remindMeAction = AlertAction(
                    name: "delegation.closewarning.remindmeaction".localized,
                    completion: nil,
                    style: .default
                )

                let alertOptions = AlertOptions(
                    title: "delegation.closewarning.title".localized,
                    message: String(format: "delegation.closewarning.message".localized, accounts.map({ $0.displayName }).joined(separator: "\n")),
                    actions: [remindMeAction]
                )

                self.showAlert(with: alertOptions)
            }
            .store(in: &cancellables)
    }

    func importWallet(from url: URL) {
        guard defaultProvider.keychainWrapper().passwordCreated() else {
            showErrorAlert(ViewError.simpleError(localizedReason: "import.noUserCreated".localized))
            return
        }
        let importCoordinator = ImportCoordinator(navigationController: TransparentNavigationController(),
                                                  dependencyProvider: defaultProvider,
                                                  parentCoordinator: self,
                                                  importFileUrl: url)
        importCoordinator.navigationController.modalPresentationStyle = .fullScreen

        if navigationController.topPresented() is IdentityProviderWebViewViewController {
            navigationController.dismiss(animated: true) { [weak self] in
                self?.presentImportView(importCoordinator: importCoordinator)
                self?.defaultProvider.storageManager().removeUnfinishedAccountsAndRelatedIdentities()
            }
        } else {
            presentImportView(importCoordinator: importCoordinator)
            defaultProvider.storageManager().removeAccountsWithoutAddress()
        }
    }

    private func presentImportView(importCoordinator: ImportCoordinator) {
        navigationController.present(importCoordinator.navigationController, animated: true)
        importCoordinator.navigationController.presentationController?.delegate = self
        importCoordinator.start()
        childCoordinators.append(importCoordinator)
    }

    func showInitialIdentityCreation() {
        if FeatureFlag.enabledFlags.contains(.recoveryCode) {
            if defaultProvider.seedMobileWallet().hasSetupRecoveryPhrase {
                showSeedIdentityCreation()
            } else {
                let recoveryPhraseCoordinator = RecoveryPhraseCoordinator(
                    dependencyProvider: defaultProvider,
                    navigationController: navigationController,
                    delegate: self
                )
                recoveryPhraseCoordinator.start()
                self.navigationController.viewControllers = Array(self.navigationController.viewControllers.lastElements(1))
                childCoordinators.append(recoveryPhraseCoordinator)
                self.navigationController.setupBaseNavigationControllerStyle()
            }
        } else {
            let initialAccountCreateCoordinator = InitialAccountsCoordinator(navigationController: navigationController,
                                                                             parentCoordinator: self,
                                                                             identitiesProvider: defaultProvider,
                                                                             accountsProvider: defaultProvider)
            initialAccountCreateCoordinator.start()
            navigationController.viewControllers = Array(navigationController.viewControllers.lastElements(1))
            childCoordinators.append(initialAccountCreateCoordinator)
            navigationController.setupBaseNavigationControllerStyle()
        }
    }
    
    func showSeedIdentityCreation() {
        let coordinator = SeedIdentitiesCoordinator(
            navigationController: navigationController,
            action: .createInitialIdentity,
            dependencyProvider: defaultProvider,
            delegate: self
        )
        
        coordinator.start()
        
        childCoordinators.append(coordinator)
        self.navigationController.setupBaseNavigationControllerStyle()
    }
    
    func logout() {
        let keyWindow = UIApplication.shared.windows.filter { $0.isKeyWindow }.first
        if var topController = keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            
            if (topController as? TransparentNavigationController)?.viewControllers.last is EnterPasswordViewController {
                return
            }
            
            topController.dismiss(animated: false) {
                Logger.trace("logout due to application timeout")
                self.childCoordinators.removeAll()
                self.showLogin()
            }
        }
    }

    func checkPasswordChangeDidSucceed() {
        if AppSettings.passwordChangeInProgress {
            showErrorAlertWithHandler(ViewError.simpleError(localizedReason: "viewError.passwordChangeFailed".localized)) {
                // Proceed with the password change.
                self.requestUserPassword(keychain: self.defaultProvider.keychainWrapper())
                    .sink(receiveError: { [weak self] error in
                        if case GeneralError.userCancelled = error { return }
                        self?.showErrorAlert(ErrorMapper.toViewError(error: error))
                    }, receiveValue: { [weak self] newPassword in

                        self?.defaultProvider.keychainWrapper().getValue(for: KeychainKeys.oldPassword.rawValue, securedByPassword: newPassword)
                            .onSuccess { oldPassword in

                                let accounts = self?.defaultProvider.storageManager().getAccounts().filter {
                                    !$0.isReadOnly && $0.transactionStatus == .finalized
                                }

                                if accounts != nil {
                                    for account in accounts! {
                                        let res = self?.defaultProvider.mobileWallet().updatePasscode(for: account,
                                                                                                      oldPwHash: oldPassword,
                                                                                                      newPwHash: newPassword)
                                        switch res {
                                        case .success:
                                            if let name = account.name {
                                                Logger.debug("successfully reencrypted account with name: \(name)")
                                            }
                                        case .failure, .none:
                                            if let name = account.name {
                                                Logger.debug("could not reencrypted account with name: \(name)")
                                            }
                                        }
                                    }
                                }
                            }

                        // Remove old password from keychain and set transaction flag false.
                        try? self?.defaultProvider.keychainWrapper().deleteKeychainItem(withKey: KeychainKeys.oldPassword.rawValue).get()
                        AppSettings.passwordChangeInProgress = false
                    }).store(in: &self.cancellables)
            }
        }
    }
}

extension AppCoordinator: AccountsPresenterDelegate {
    func userPerformed(action: AccountCardAction, on account: AccountDataType) {
        accountsCoordinator?.userPerformed(action: action, on: account)
    }

    func enableShielded(on account: AccountDataType) {
    }

    func noValidIdentitiesAvailable() {
    }

    func tryAgainIdentity() {
    }

    func didSelectMakeBackup() {
    }

    func didSelectPendingIdentity(identity: IdentityDataType) {
    }

    func newTermsAvailable() {
        accountsCoordinator?.showNewTerms()
    }
    
    func showSettings() {
        let moreCoordinator = MoreCoordinator(navigationController: self.navigationController,
                                              dependencyProvider: defaultProvider,
                                              parentCoordinator: self)
        moreCoordinator.start()
    }
}

extension AppCoordinator: AccountsCoordinatorDelegate {
    func createNewIdentity() {
        accountsCoordinator?.showCreateNewIdentity()
    }

    func createNewAccount() {
        accountsCoordinator?.showCreateNewAccount()
    }

    func showIdentities() {
    }
}

extension AppCoordinator: InitialAccountsCoordinatorDelegate {
    func finishedCreatingInitialIdentity() {
        showMainTabbar()
        // Remove InitialAccountsCoordinator from hierarchy.
        navigationController.viewControllers = [navigationController.viewControllers.last!]
        childCoordinators.removeAll { $0 is InitialAccountsCoordinator }
    }
}

extension AppCoordinator: LoginCoordinatorDelegate {
    func loginDone() {
        defaultProvider.storageManager().removeAccountsWithoutAddress()

        let identities = defaultProvider.storageManager().getIdentities()
        let accounts = defaultProvider.storageManager().getAccounts()

        if !accounts.isEmpty || !identities.isEmpty {
            showMainTabbar()
        } else {
            showInitialIdentityCreation()
        }
        // Remove login from hierarchy.
        navigationController.viewControllers = [navigationController.viewControllers.last!]
        childCoordinators.removeAll { $0 is LoginCoordinator }

        checkPasswordChangeDidSucceed()
    }

    func passwordSelectionDone() {
        showInitialIdentityCreation()
        // Remove login from hierarchy.
        navigationController.viewControllers = [navigationController.viewControllers.last!]
        childCoordinators.removeAll { $0 is LoginCoordinator }
    }
}

extension AppCoordinator: ImportCoordinatorDelegate {
    func importCoordinatorDidFinish(_ coordinator: ImportCoordinator) {
        navigationController.dismiss(animated: true)
        childCoordinators.removeAll(where: { $0 is ImportCoordinator })

        if childCoordinators.contains(where: { $0 is InitialAccountsCoordinator }) {
            let identities = defaultProvider.storageManager().getIdentities()
            if identities.filter({ $0.state == IdentityState.confirmed || $0.state == IdentityState.pending }).first != nil {
                showMainTabbar()
            }
        }
    }

    func importCoordinator(_ coordinator: ImportCoordinator, finishedWithError error: Error) {
        navigationController.dismiss(animated: true)
        childCoordinators.removeAll(where: { $0 is ImportCoordinator })
        showErrorAlert(ErrorMapper.toViewError(error: error))
    }
}

extension AppCoordinator: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // Handle drag to dismiss on the import sheet.
        childCoordinators.removeAll(where: { $0 is ImportCoordinator })
    }
}

extension AppCoordinator: IdentitiesCoordinatorDelegate, MoreCoordinatorDelegate {
    func finishedDisplayingIdentities() {
    }

    func noIdentitiesFound() {
        navigationController.setNavigationBarHidden(true, animated: false)
        showInitialIdentityCreation()
        childCoordinators.removeAll(where: { $0 is IdentitiesCoordinator || $0 is AccountsCoordinator || $0 is MoreCoordinator })
    }
}

extension AppCoordinator: AppSettingsDelegate {

    func checkForAppSettings() {
        guard needsAppCheck else { return }
        needsAppCheck = false

        defaultProvider.appSettingsService()
            .getAppSettings()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] response in
                    self?.handleAppSettings(response: response)
                }
            )
            .store(in: &cancellables)
    }
    
    private func handleAppSettings(response: AppSettingsResponse) {
        showUpdateDialogIfNeeded(
            appSettingsResponse: response
        ) { action in
            switch action {
            case let .update(url, forced):
                if forced {
                    self.handleAppSettings(response: response)
                }
                UIApplication.shared.open(url)
            case .cancel:
                break
            }
        }
    }
}

extension AppCoordinator: RecoveryPhraseCoordinatorDelegate {
    func recoveryPhraseCoordinator(createdNewSeed seed: Seed) {
        showSeedIdentityCreation()
        childCoordinators.removeAll { $0 is RecoveryPhraseCoordinator }
    }
    
    func recoveryPhraseCoordinatorFinishedRecovery() {
        showMainTabbar()
        childCoordinators.removeAll { $0 is RecoveryPhraseCoordinator }
    }
}

extension AppCoordinator: SeedIdentitiesCoordinatorDelegate {
    func seedIdentityCoordinatorWasFinished(for identity: IdentityDataType) {
        showMainTabbar()
    }
}
