# Windows Maintenance Orchestrator

Install a visible, verifiable maintenance regimen that runs quietly in the background at the right Windows lifecycle moments.

The project distills the scheduler built during the LeanPerformance V2 work: daily and weekly maintenance, SYSTEM startup refresh, post-sign-in user refresh, post-Windows-Update cleanup, restart/shutdown markers, a periodic self-heal watchdog, hidden launchers, manual test modes, and status reports.

## Task map

| Task | Default trigger | Principal | Purpose |
|---|---|---|---|
| Daily | 12:30 PM | SYSTEM | Old temp files, DNS cache, report retention. |
| Weekly | Saturday 1:00 PM | SYSTEM | Component cleanup, SSD retrim, health check. |
| Startup | At boot, delayed | SYSTEM | Recover missed work and record startup health. |
| Logon | At sign-in, delayed | Current user | User-scope refresh and success marker. |
| Post Update | Windows Update event | SYSTEM | Cleanup and health check after successful update activity. |
| Shutdown Marker | User32 event 1074 | SYSTEM | Record restart/shutdown intent for the next startup pass. |
| Self Heal | Every 6 hours | SYSTEM | Recreate missing/disabled orchestrator tasks. |

## Install

Audit the proposed task definitions:

```powershell
.\src\Install-Orchestrator.ps1
```

Install from an elevated PowerShell window:

```powershell
.\src\Install-Orchestrator.ps1 -Apply
```

Verify:

```powershell
.\src\Invoke-Maintenance.ps1 -Mode Verify
```

Every maintenance mode also supports a direct manual test. The scripts write JSON and text logs rather than relying on a flashing terminal window.

## Safety

- No third-party app uninstallation.
- No broad service/task pruning.
- No browser, DNS provider, hosts, firewall, VPN, or permanent-lockdown reconfiguration.
- Cleanup is restricted to known cache/temp/report roots and age thresholds.
- Weekly component cleanup uses supported Windows tools.
- Multiple instances are ignored to prevent task pileups.
- Failures remain in reports and Task Scheduler history.

## License

MIT.

