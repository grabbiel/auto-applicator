import Engine

// The same executable doubles as the helper-process supervisor (see Supervisor): handle that before any UI exists.
if CommandLine.arguments.contains(Supervisor.flag) {
    Supervisor.runSupervisor(CommandLine.arguments)
}
AutoApplicatorApp.main()
