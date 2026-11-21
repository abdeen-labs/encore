from .protocol import take_over_stdout

# Must happen before anything else can print: stdout becomes protocol-only.
take_over_stdout()

from .worker import main  # noqa: E402

main()
