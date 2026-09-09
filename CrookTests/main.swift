import Foundation

// argv dispatch: ./scripts/test.sh [suite ...]
let requested = Set(CommandLine.arguments.dropFirst())
func want(_ s: String) -> Bool { requested.isEmpty || requested.contains(s) }

if want("reach")    { ReachTests.run(); ReachTests.perf() }
if want("deadpath") { DeadPathTests.run() }
if want("seen")     { SeenTests.run(); SeenTests.pruning() }
if want("bytes")    { ByteTests.run() }
if want("diff")     { DiffTests.run(); DiffTests.unified() }
if want("validate") { ValidationTests.run() }

if want("agent")    { AgentTests.run(); AgentTests.transport(); AgentTests.authClassification(); AgentTests.askpass(); AgentTests.latency() }
if want("machines") { MachinesTests.run() }
if want("roots")   { ProjectRootsTests.run() }
if want("doclife") { DocumentLifetimeTests.run() }
if want("regress")  { RegressionTests.run() }

exit(T.summary())
