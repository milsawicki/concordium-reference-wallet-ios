//
//  RecoveryPhraseInputPresenter.swift
//  ConcordiumWallet
//
//  Created by Niels Christian Friis Jakobsen on 28/07/2022.
//  Copyright © 2022 concordium. All rights reserved.
//

import Foundation

protocol RecoveryPhraseInputPresenterDelegate: AnyObject {
    func phraseInputReceived(validPhrase: RecoveryPhrase)
}

class RecoveryPhraseInputPresenter: SwiftUIPresenter<RecoveryPhraseInputViewModel> {
    private let recoveryService: RecoveryPhraseServiceProtocol
    private weak var delegate: RecoveryPhraseInputPresenterDelegate?
    
    init(
        recoveryService: RecoveryPhraseServiceProtocol,
        delegate: RecoveryPhraseInputPresenterDelegate
    ) {
        self.recoveryService = recoveryService
        self.delegate = delegate
        
        super.init(
            viewModel: .init(
                title: "recoveryphrase.recover.input.title".localized,
                clearAll: "recoveryphrase.recover.input.clearall".localized,
                clearBelow: "recoveryphrase.recover.input.clearbelow".localized,
                selectedWords: Array(repeating: "", count: 24),
                currentInput: "",
                currentSuggestions: [],
                error: nil
            )
        )
        
        viewModel.navigationTitle = "recoveryphrase.recover.input.navigationtitle".localized
        
        viewModel.$currentInput.sink { [weak self] word in
            if word.count > 1 {
                self?.viewModel.currentSuggestions = recoveryService.suggestions(for: word)
            } else {
                self?.viewModel.currentSuggestions = []
            }
        }.store(in: &cancellables)
    }
    
    override func receive(event: RecoveryPhraseInputEvent) {
        switch event {
        case .clearAll:
            viewModel.selectedWords = Array(repeating: "", count: 24)
            viewModel.currentSuggestions = []
        case .clearBelow(let index):
            viewModel.selectedWords = viewModel.selectedWords[0...index] + Array(repeating: "", count: 23 - index)
        case .wordSelected(let index, let word):
            // TODO: Test phrase
//            viewModel.selectedWords = ["interest", "spy", "champion", "install", "appear", "solution", "digital", "intact", "expose", "order", "minute", "match", "train", "possible", "practice", "leave", "first", "matter", "zero", "brief", "tag", "mushroom", "anger", "tide"]
//            viewModel.selectedWords = ["grant", "mandate", "usage", "asthma", "invite", "state", "silent", "hover", "lunch", "result", "diagram", "chapter", "ecology", "orbit", "shed", "subject", "bachelor", "violin", "tape", "visit", "rigid", "leopard", "myself", "minute"]
//            viewModel.selectedWords = ["ginger", "name", "viable", "else", "sight", "agree", "stamp", "draw", "ticket", "course", "ceiling", "slot", "water", "siren", "hood", "spatial", "attend", "paddle", "hockey", "goat", "turkey", "feature", "goddess", "idea"]
            viewModel.selectedWords[index] = word
            if viewModel.selectedWords.allSatisfy({ !$0.isEmpty }) {
                switch recoveryService.validate(recoveryPhrase: viewModel.selectedWords) {
                case let .success(recoveryPhrase):
                    delegate?.phraseInputReceived(validPhrase: recoveryPhrase)
                case .failure:
                    viewModel.error = "recoveryphrase.recover.input.validationerror".localized
                }
            }
        }
    }
}
