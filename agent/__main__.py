import sys
import os

AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
AGENT_BPLUS = os.path.join(AGENT_DIR, "agent b+")

sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)


def main():
    from cli import AgentCLI
    cli = AgentCLI()
    cli.boot()

    single_shot = None
    if len(sys.argv) > 1:
        single_shot = " ".join(sys.argv[1:])

    if single_shot:
        print(f"\n  B+ > {single_shot}")
        result = cli.handle_command(single_shot)
        if result:
            print()
            print(result)
            print()
        return

    print("  Type your question, or /help for commands.\n")

    while True:
        try:
            line = input("B+ > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n  Goodbye.")
            break

        if not line:
            continue

        result = cli.handle_command(line)
        if result == "EXIT":
            print("  Goodbye.")
            break
        if result:
            print()
            print(result)
            print()


if __name__ == "__main__":
    main()
