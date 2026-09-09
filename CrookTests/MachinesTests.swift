import Foundation

/// Reading ~/.ssh/config the way ssh does.
///
/// The Connect field offers every Host alias it finds there, so what it finds
/// is what a person can pick. The first reader matched "Host " and a space,
/// which missed the aliases written with a tab or an `=`, missed everything in
/// an Include, and offered `!bastion` — a negation pattern — as a machine.
enum MachinesTests {

    static func run() {
        T.suite("machines — reading ~/.ssh/config the way ssh does")

        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("crook-home-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try? fm.createDirectory(at: ssh.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let config = """
        # the usual
        Host mac-mini
          HostName 100.1.2.3
          User mac-mini
        Host\tstudio staging
        Host=lab
        Host * !bastion
        Host web-?
        Include config.d/*
        Include ~/.ssh/extra
        """
        try? config.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try? "Host office\n".write(to: ssh.appendingPathComponent("config.d/work"), atomically: true, encoding: .utf8)
        try? "host home-server\n".write(to: ssh.appendingPathComponent("extra"), atomically: true, encoding: .utf8)

        let saved = Paths.homeOverride
        Paths.homeOverride = home.path
        defer { Paths.homeOverride = saved }

        let hosts = Machines.shared.sshConfigHosts()
        let list = hosts.joined(separator: " ")

        T.ok("M-01  a plain Host line is offered", hosts.contains("mac-mini"), list)
        T.ok("M-02  a tab after the keyword still counts, and both names on the line",
             hosts.contains("studio") && hosts.contains("staging"), list)
        T.ok("M-03  the Host=name form counts", hosts.contains("lab"), list)
        T.ok("M-04  a negation is not a machine", !hosts.contains("!bastion"), list)
        T.ok("M-05  nor is a pattern", !hosts.contains("*") && !hosts.contains("web-?"), list)
        T.ok("M-06  Include relative to ~/.ssh is followed", hosts.contains("office"), list)
        T.ok("M-07  and so is Include with a ~ path, keyword in any case",
             hosts.contains("home-server"), list)
        T.eq("M-08  in file order, without duplicates",
             list, "mac-mini studio staging lab office home-server")

        // No config at all is the common first-run case, and must be quiet.
        Paths.homeOverride = home.appendingPathComponent("nowhere").path
        T.ok("M-09  no config file means no hosts and no fuss", Machines.shared.sshConfigHosts().isEmpty)
    }
}
