//
//  StakeCoordinator.swift
//  ConcordiumWallet
//
//  Created by Ruxandra Nistor on 03/03/2022.
//  Copyright © 2022 concordium. All rights reserved.
//

import Foundation
import UIKit

protocol DelegationCoordinatorDelegate: AnyObject {
    func finished()
}


class DelegationCoordinator: Coordinator {
    var childCoordinators = [Coordinator]()
    var navigationController: UINavigationController
    
    weak var delegate: DelegationCoordinatorDelegate?
    
    private var account: AccountDataType
    
    private var dependencyProvider: StakeCoordinatorDependencyProvider
    
    init(navigationController: UINavigationController, dependencyProvider: StakeCoordinatorDependencyProvider, account: AccountDataType) {
        self.navigationController = navigationController
        self.dependencyProvider = dependencyProvider
        self.account = account
    }
    
    func start() {
        showAmountInput()
    }
    
    func showAmountInput() {
        let vc = StakeAmountInputFactory.create(with: DelegationAmountInputPresenter(account: account, delegate: self))
        navigationController.pushViewController(vc, animated: true)
    }
    
}

extension DelegationCoordinator: DelegationAmountInputPresenterDelegate {
    
}
