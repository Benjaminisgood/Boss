import Foundation

extension BossCLI {
    var recordUsage: String {
        """
Record commands:
    boss record list [--all] [--archived] [--limit N]
    boss record search <query> [--limit N] [--json]
    boss record create <filename> [text]
    boss record append <record-id> <text> [--json]
    boss record replace <record-id> <text> [--json]
    boss record import <file-path>
    boss record show <record-id>
    boss record delete <record-id>
"""
    }

    var taskUsage: String {
        """
Task commands:
    boss task list
    boss task logs <task-id> [--limit N]
    boss task run <task-id>
"""
    }

    var assistantUsage: String {
        """
Assistant commands:
    boss assistant ask <request> [--source <source>] [--json]
    boss assistant confirm <token> [--source <source>] [--json]
"""
    }

    var skillsUsage: String {
        """
Skills commands:
    boss skills list
    boss skills manifest [--json]
    boss skills catalog [--json]
    boss skills refresh-manifest
"""
    }

    var skillUsage: String {
        """
Skill commands:
    boss skill run <skill-ref> [input] [--source <source>] [--json]
"""
    }

    var commandsUsage: String {
        """
Commands catalog:
    boss commands [--json]
    boss commands list [--json]
"""
    }

    var interfaceUsage: String {
        """
Interface commands:
    boss interface list [--json]
    boss interface run <name> [--args-json <json>] [--source <source>] [--json]
"""
    }

    var usage: String {
        """
Boss CLI

Usage:
    boss [--storage <path>] help
    boss [--storage <path>] record <subcommand>
    boss [--storage <path>] task <subcommand>
    boss [--storage <path>] assistant <subcommand>
    boss [--storage <path>] skills <subcommand>
    boss [--storage <path>] skill <subcommand>
    boss [--storage <path>] commands [--json]
    boss [--storage <path>] interface <subcommand>

Global options:
    --storage, -s   Override storage directory (default follows app config)
    BOSS_STORAGE_PATH env var is also supported.

\(recordUsage)
\(taskUsage)
\(assistantUsage)
\(skillsUsage)
\(skillUsage)
\(commandsUsage)
\(interfaceUsage)
"""
    }
}
