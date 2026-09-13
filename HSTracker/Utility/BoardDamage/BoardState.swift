//
//  BoardState.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

class BoardState {
    private(set) var player: PlayerBoard
    private(set) var opponent: PlayerBoard

    /// Steps of a turn in which the current player can still attack. MAIN_READY is left out because
    /// that is when NUM_TURNS_IN_PLAY, EXHAUSTED and NUM_ATTACKS_THIS_TURN are reset, and MAIN_END,
    /// MAIN_CLEANUP and MAIN_NEXT because the turn is over.
    static let actingSteps = Set([Step.main_start_triggers, .main_start, .main_action, .main_combat,
                                  .main_pre_action, .main_post_action].map { $0.rawValue })

    /// Tags whose change on an entity in play can change a board damage number
    private static let inPlayTags: Set<GameTag> = [
        .num_attacks_this_turn, .exhausted, .frozen, .atk, .damage, .health, .charge, .windfury,
        .mega_windfury, .cant_attack, .cannot_attack_heroes, .dormant, .titan, .titan_ability_used_1,
        .titan_ability_used_2, .titan_ability_used_3, .heropower_activations_this_turn, .hero_power_disabled,
        .silenced, .hide_stats, .just_played, .controller, .cost, .armor
    ]
    /// Turn and mana tags, which live on the game and player entities
    private static let turnTags: Set<GameTag> = [.step, .current_player, .resources, .resources_used, .temp_resources]

    init(player: PlayerBoard, opponent: PlayerBoard) {
        self.player = player
        self.opponent = opponent
    }

    convenience init(game: Game) {
        self.init(player: game.player.board, opponent: game.opponent.board,
                  playerEntity: game.playerEntity, opponentEntity: game.opponentEntity,
                  step: game.gameEntity?[.step] ?? 0)
    }

    /// - Parameters:
    ///   - player: the player's entities in play
    ///   - opponent: the opponent's entities in play
    ///   - playerEntity: the player's player entity, holding CURRENT_PLAYER and the mana tags
    ///   - opponentEntity: the opponent's player entity
    ///   - step: the GameEntity's STEP
    convenience init(player: [Entity], opponent: [Entity], playerEntity: Entity?, opponentEntity: Entity?, step: Int) {
        self.init(player: BoardState.createBoard(list: player, playerEntity: playerEntity, step: step),
                  opponent: BoardState.createBoard(list: opponent, playerEntity: opponentEntity, step: step))
    }

    /// Whether the side with this player entity is the one on turn. CURRENT_PLAYER is what the game
    /// flips at the turn change, unlike HDT's TURN parity, which can drift on extra turns.
    static func isCurrent(playerEntity: Entity?) -> Bool {
        return playerEntity?[.current_player] == 1
    }

    static func isActing(isCurrent: Bool, step: Int) -> Bool {
        return isCurrent && actingSteps.contains(step)
    }

    /// Whether this tag change can change what the board damage counters show
    static func affectsBoardDamage(entity: Entity, tag: GameTag, prevValue: Int, value: Int) -> Bool {
        if turnTags.contains(tag) {
            return true
        }
        if tag == .zone {
            return prevValue == Zone.play.rawValue || value == Zone.play.rawValue
        }
        return inPlayTags.contains(tag) && entity.isInPlay
    }

    /// "Threat" semantics: whether the other side's board could kill this hero on its next turn if
    /// nothing changes. Nothing uses these yet (HDT has the same unused helpers).
    func isPlayerDeadToBoard() -> Bool {
        guard let hero = player.hero else {
            return true
        }
        return opponent.hasInfiniteDamageNextTurn || opponent.damageNextTurn >= hero.health
    }

    func isOpponentDeadToBoard() -> Bool {
        guard let hero = opponent.hero else {
            return true
        }
        return player.hasInfiniteDamageNextTurn || player.damageNextTurn >= hero.health
    }

    private class func createBoard(list: [Entity], playerEntity: Entity?, step: Int) -> PlayerBoard {
        let current = BoardState.isCurrent(playerEntity: playerEntity)
        return PlayerBoard(list: list, isCurrent: current,
                           isActing: BoardState.isActing(isCurrent: current, step: step),
                           playerEntity: playerEntity)
    }
}
