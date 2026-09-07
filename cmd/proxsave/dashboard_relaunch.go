package main

import (
	"context"
	"errors"
	"os"
	"strings"

	"github.com/tis24dev/proxsave/internal/logging"
	"github.com/tis24dev/proxsave/internal/safeexec"
	"github.com/tis24dev/proxsave/internal/types"
	"github.com/tis24dev/proxsave/internal/ui/shell"
)

var (
	dashboardRelaunchCommandContext = safeexec.TrustedCommandContext
	dashboardRelaunchAfterUpgrade   = relaunchDashboardAfterUpgrade
)

// relaunchDashboardAfterUpgrade returns the code the process should exit with, not
// a plain success: the relaunched dashboard is a full interactive session, and its
// exit code is that session's outcome. Replacing it with 0 loses what the operator
// just did in there.

func relaunchInstalledDashboard(ctx context.Context, execPath string) error {
	execPath = strings.TrimSpace(execPath)
	if execPath == "" {
		return errors.New("installed executable path is empty")
	}
	cmd, err := dashboardRelaunchCommandContext(ctx, execPath)
	if err != nil {
		return err
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func relaunchDashboardAfterUpgrade(ctx context.Context, execPath string, bootstrap *logging.BootstrapLogger) int {
	done := logging.DebugStartBootstrap(bootstrap, "dashboard relaunch", "exec=%s", execPath)
	err := relaunchInstalledDashboard(ctx, execPath)

	// A child that RAN and exited says something about the session the operator just
	// had; anything else says nothing ever took over the terminal, and only that is a
	// reload failure. childReachedItsOwnExit draws exactly that line, and its own doc
	// comment explains why the error is the only thing that can.
	setupErr := err
	code := types.ExitSuccess.Int()
	switch {
	case err == nil:
	case !childReachedItsOwnExit(err):
		if bootstrap != nil {
			bootstrap.Error("Dashboard reload failed after upgrade: %v", err)
		}
		code = types.ExitGenericError.Int()
	default:
		// The reload worked, so the debug workflow must not close as failed and no
		// error line is owed: this code belongs to the session, and it is carried out
		// to the shell rather than announced here.
		setupErr = nil
		code = exitCodeFromErr(err)
		logging.DebugStepBootstrap(bootstrap, "dashboard relaunch",
			"reload succeeded; the reloaded dashboard exited code=%d", code)
	}
	done(setupErr)
	return code
}

func closeDashboardAndRelaunch(ctx context.Context, session *shell.Session, execPath string, bootstrap *logging.BootstrapLogger) int {
	_ = session.Close()
	return dashboardRelaunchAfterUpgrade(ctx, execPath, bootstrap)
}
