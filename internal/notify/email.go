package notify

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/tis24dev/proxmox-backup/internal/logging"
	"github.com/tis24dev/proxmox-backup/internal/types"
)

// EmailDeliveryMethod represents the email delivery method
type EmailDeliveryMethod string

const (
	EmailDeliveryRelay    EmailDeliveryMethod = "relay"
	EmailDeliverySendmail EmailDeliveryMethod = "sendmail"
)

// EmailConfig holds email notification configuration
type EmailConfig struct {
	Enabled          bool
	DeliveryMethod   EmailDeliveryMethod
	FallbackSendmail bool
	AttachLogFile    bool
	SubjectOverride  string
	Recipient        string // Empty = auto-detect
	From             string
	CloudRelayConfig CloudRelayConfig
}

// EmailNotifier implements the Notifier interface for Email
type EmailNotifier struct {
	config      EmailConfig
	logger      *logging.Logger
	proxmoxType types.ProxmoxType
}

// Email validation regex
var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)

// NewEmailNotifier creates a new Email notifier
func NewEmailNotifier(config EmailConfig, proxmoxType types.ProxmoxType, logger *logging.Logger) (*EmailNotifier, error) {
	if !config.Enabled {
		return &EmailNotifier{
			config:      config,
			logger:      logger,
			proxmoxType: proxmoxType,
		}, nil
	}

	// Validate delivery method
	if config.DeliveryMethod != EmailDeliveryRelay && config.DeliveryMethod != EmailDeliverySendmail {
		return nil, fmt.Errorf("invalid email delivery method: %s (must be 'relay' or 'sendmail')", config.DeliveryMethod)
	}

	// Validate from address
	if config.From == "" {
		config.From = "no-reply@proxmox.tis24.it"
	}

	return &EmailNotifier{
		config:      config,
		logger:      logger,
		proxmoxType: proxmoxType,
	}, nil
}

// Name returns the notifier name
func (e *EmailNotifier) Name() string {
	return "Email"
}

// IsEnabled returns whether email notifications are enabled
func (e *EmailNotifier) IsEnabled() bool {
	return e.config.Enabled
}

// IsCritical returns whether email failures should abort backup (always false)
func (e *EmailNotifier) IsCritical() bool {
	return false // Notification failures never abort backup
}

// Send sends an email notification
func (e *EmailNotifier) Send(ctx context.Context, data *NotificationData) (*NotificationResult, error) {
	startTime := time.Now()
	result := &NotificationResult{
		Method:   "email",
		Metadata: make(map[string]interface{}),
	}

	if !e.config.Enabled {
		e.logger.Debug("Email notifications disabled")
		result.Success = false
		result.Duration = time.Since(startTime)
		return result, nil
	}

	// Resolve recipient
	recipient := e.config.Recipient
	if recipient == "" {
		e.logger.Debug("Email recipient not configured, attempting auto-detection...")
		var err error
		recipient, err = e.detectRecipient(ctx)
		if err != nil {
			e.logger.Warning("WARNING: Failed to detect email recipient: %v", err)
			e.logger.Warning("WARNING: Using fallback recipient: root@localhost")
			recipient = "root@localhost"
		} else {
			e.logger.Debug("Auto-detected email recipient: %s", recipient)
		}
	}

	// Validate recipient email format
	if !emailRegex.MatchString(recipient) {
		e.logger.Warning("WARNING: Invalid email format: %s", recipient)
	}

	// Build email subject and body
	subject := BuildEmailSubject(data)
	if strings.TrimSpace(e.config.SubjectOverride) != "" {
		subject = strings.TrimSpace(e.config.SubjectOverride)
	}
	htmlBody := BuildEmailHTML(data)
	textBody := BuildEmailPlainText(data)

	// Attempt delivery based on method
	var err error
	var relayErr error // Store original relay error if fallback is used

	if e.config.DeliveryMethod == EmailDeliveryRelay {
		result.Method = "email-relay"
		err = e.sendViaRelay(ctx, recipient, subject, htmlBody, textBody, data)

		// Fallback to sendmail if relay fails and fallback is enabled
		if err != nil && e.config.FallbackSendmail {
			relayErr = err // Store original relay error
			e.logger.Warning("WARNING: Cloud relay failed: %v", err)
			e.logger.Info("Attempting fallback to sendmail...")

			result.Method = "email-sendmail-fallback"
			result.UsedFallback = true
			err = e.sendViaSendmail(ctx, recipient, subject, htmlBody, textBody, data)

			// If fallback succeeds, preserve the original relay error for logging
			if err == nil {
				result.Error = relayErr
			}
		}
	} else {
		result.Method = "email-sendmail"
		err = e.sendViaSendmail(ctx, recipient, subject, htmlBody, textBody, data)
	}

	// Handle result
	result.Duration = time.Since(startTime)

	if err != nil {
		// Both primary and fallback failed (or no fallback configured)
		e.logger.Warning("WARNING: Failed to send email notification: %v", err)
		result.Success = false
		result.Error = err
		return result, nil // Non-critical error
	}

	// Success (either primary or fallback)
	if result.UsedFallback {
		// Fallback succeeded after relay failure
		e.logger.Warning("⚠️ Email sent via fallback after relay failure")
		e.logger.Info("Email provider confirmed delivery to %s via %s", recipient, describeEmailMethod(result.Method))
	} else {
		// Primary method succeeded
		e.logger.Info("Email provider confirmed delivery to %s via %s", recipient, describeEmailMethod(result.Method))
	}

	result.Success = true
	return result, nil
}

func describeEmailMethod(method string) string {
	switch method {
	case "email-relay":
		return "cloud relay"
	case "email-sendmail":
		return "sendmail"
	case "email-sendmail-fallback":
		return "sendmail fallback"
	default:
		return method
	}
}

// detectRecipient attempts to auto-detect the email recipient from Proxmox configuration
// Replicates Bash logic: jq -r '.[] | select(.userid=="root@pam") | .email'
func (e *EmailNotifier) detectRecipient(ctx context.Context) (string, error) {
	var cmd *exec.Cmd

	switch e.proxmoxType {
	case types.ProxmoxVE:
		// Try to get root user email from PVE
		cmd = exec.CommandContext(ctx, "pveum", "user", "list", "--output-format", "json")

	case types.ProxmoxBS:
		// Try to get root user email from PBS
		cmd = exec.CommandContext(ctx, "proxmox-backup-manager", "user", "list", "--output-format", "json")

	default:
		return "", fmt.Errorf("unknown Proxmox type: %s", e.proxmoxType)
	}

	// Execute command
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to query Proxmox user list: %w", err)
	}

	// Parse JSON array to find root@pam user
	// Replicates: jq -r '.[] | select(.userid=="root@pam") | .email'
	var users []map[string]interface{}
	if err := json.Unmarshal(output, &users); err != nil {
		return "", fmt.Errorf("failed to parse user list JSON: %w", err)
	}

	// Search for root@pam user specifically
	for _, user := range users {
		userid, useridOk := user["userid"].(string)
		if !useridOk {
			continue
		}

		// Check if this is the root@pam user
		if userid == "root@pam" {
			email, emailOk := user["email"].(string)
			if emailOk && email != "" {
				e.logger.Debug("Found root@pam email: %s", email)
				return email, nil
			}
			// root@pam found but no email configured
			return "", fmt.Errorf("root@pam user exists but has no email configured")
		}
	}

	return "", fmt.Errorf("root@pam user not found in Proxmox configuration")
}

// sendViaRelay sends email via cloud relay
func (e *EmailNotifier) sendViaRelay(ctx context.Context, recipient, subject, htmlBody, textBody string, data *NotificationData) error {
	// Build payload
	payload := EmailRelayPayload{
		To:            recipient,
		Subject:       subject,
		Report:        buildReportData(data),
		Timestamp:     time.Now().Unix(),
		ServerMAC:     data.ServerMAC,
		ScriptVersion: data.ScriptVersion,
		ServerID:      data.ServerID,
	}

	// Send via cloud relay
	return sendViaCloudRelay(ctx, e.config.CloudRelayConfig, payload, e.logger)
}

// isMTAServiceActive checks if a Mail Transfer Agent service is running
func (e *EmailNotifier) isMTAServiceActive(ctx context.Context) (bool, string) {
	services := []string{"postfix", "sendmail", "exim4"}

	if _, err := exec.LookPath("systemctl"); err != nil {
		return false, "systemctl not available"
	}

	for _, service := range services {
		cmd := exec.CommandContext(ctx, "systemctl", "is-active", service)
		if err := cmd.Run(); err == nil {
			e.logger.Debug("MTA service %s is active", service)
			return true, service
		}
	}

	return false, "no MTA service active"
}

// checkMTAConfiguration checks if MTA configuration files exist
func (e *EmailNotifier) checkMTAConfiguration() (bool, string) {
	configFiles := []struct {
		path string
		mta  string
	}{
		{"/etc/postfix/main.cf", "Postfix"},
		{"/etc/mail/sendmail.cf", "Sendmail"},
		{"/etc/exim4/exim4.conf", "Exim4"},
	}

	for _, cf := range configFiles {
		if info, err := os.Stat(cf.path); err == nil && !info.IsDir() {
			e.logger.Debug("Found %s configuration at %s", cf.mta, cf.path)
			return true, cf.mta
		}
	}

	return false, "no MTA configuration found"
}

// checkRelayHostConfigured checks if Postfix relay host is configured
func (e *EmailNotifier) checkRelayHostConfigured(ctx context.Context) (bool, string) {
	configPath := "/etc/postfix/main.cf"
	if _, err := os.Stat(configPath); err != nil {
		return false, "main.cf not found"
	}

	content, err := os.ReadFile(configPath)
	if err != nil {
		e.logger.Debug("Failed to read postfix config: %v", err)
		return false, "cannot read config"
	}

	// Look for relayhost setting
	re := regexp.MustCompile(`(?m)^relayhost\s*=\s*(.+)$`)
	matches := re.FindStringSubmatch(string(content))

	if len(matches) > 1 {
		relayhost := strings.TrimSpace(matches[1])
		if relayhost != "" && relayhost != "[]" {
			e.logger.Debug("Relay host configured: %s", relayhost)
			return true, relayhost
		}
	}

	e.logger.Debug("No relay host configured in Postfix")
	return false, "no relay host"
}

// checkMailQueue checks the mail queue status
func (e *EmailNotifier) checkMailQueue(ctx context.Context) (int, error) {
	// Try mailq command (works for both Postfix and Sendmail)
	mailqPath := "/usr/bin/mailq"
	if _, err := exec.LookPath("mailq"); err != nil {
		if _, err := exec.LookPath(mailqPath); err != nil {
			return 0, fmt.Errorf("mailq command not found")
		}
	} else {
		mailqPath = "mailq"
	}

	cmd := exec.CommandContext(ctx, mailqPath)
	output, err := cmd.Output()
	if err != nil {
		return 0, fmt.Errorf("mailq failed: %w", err)
	}

	// Parse output to count queued messages
	outputStr := string(output)
	if strings.Contains(outputStr, "Mail queue is empty") {
		e.logger.Debug("Mail queue is empty")
		return 0, nil
	}

	// Count lines that look like queue entries
	lines := strings.Split(outputStr, "\n")
	queueCount := 0
	for _, line := range lines {
		// Basic heuristic: lines with queue IDs (hex strings) and @ symbols
		if len(line) > 10 && strings.Contains(line, "@") {
			// Skip header and footer lines
			if !strings.Contains(line, "Mail queue") && !strings.Contains(line, "Total requests") {
				queueCount++
			}
		}
	}

	if queueCount > 0 {
		e.logger.Debug("Found %d message(s) in mail queue", queueCount)
	}

	return queueCount, nil
}

// checkRecentMailLogs checks recent mail log entries for errors
func (e *EmailNotifier) checkRecentMailLogs() []string {
	logFiles := []string{
		"/var/log/mail.log",
		"/var/log/maillog",
		"/var/log/mail.err",
	}

	var errors []string

	for _, logFile := range logFiles {
		if _, err := os.Stat(logFile); err != nil {
			continue
		}

		// Read last 50 lines
		cmd := exec.Command("tail", "-n", "50", logFile)
		output, err := cmd.Output()
		if err != nil {
			continue
		}

		lines := strings.Split(string(output), "\n")
		for _, line := range lines {
			lower := strings.ToLower(line)
			// Look for common error patterns
			if strings.Contains(lower, "error") ||
				strings.Contains(lower, "failed") ||
				strings.Contains(lower, "rejected") ||
				strings.Contains(lower, "deferred") ||
				strings.Contains(lower, "connection refused") ||
				strings.Contains(lower, "timeout") {
				errors = append(errors, strings.TrimSpace(line))
			}
		}

		// Only check first available log file
		if len(errors) > 0 {
			break
		}
	}

	return errors
}

// sendViaSendmail sends email via local sendmail command
func (e *EmailNotifier) sendViaSendmail(ctx context.Context, recipient, subject, htmlBody, textBody string, data *NotificationData) error {
	e.logger.Debug("sendViaSendmail() starting for recipient: %s", recipient)

	// ========================================================================
	// PRE-FLIGHT MTA DIAGNOSTIC CHECKS
	// ========================================================================
	e.logger.Debug("=== Pre-flight MTA diagnostic checks ===")

	// Check if sendmail exists
	sendmailPath := "/usr/sbin/sendmail"
	if _, err := exec.LookPath(sendmailPath); err != nil {
		return fmt.Errorf("sendmail not found at %s - please install postfix or configure email relay", sendmailPath)
	}
	e.logger.Debug("✓ Sendmail binary found at %s", sendmailPath)

	// Check MTA service status
	if active, service := e.isMTAServiceActive(ctx); active {
		e.logger.Debug("✓ MTA service '%s' is active", service)
	} else {
		e.logger.Warning("⚠ No MTA service appears to be running (checked: postfix, sendmail, exim4)")
		e.logger.Warning("  Emails may be accepted but not delivered. Consider using EMAIL_DELIVERY_METHOD=relay")
	}

	// Check MTA configuration
	if hasConfig, mtaType := e.checkMTAConfiguration(); hasConfig {
		e.logger.Debug("✓ %s configuration found", mtaType)

		// For Postfix, check relay configuration
		if mtaType == "Postfix" {
			if hasRelay, relayHost := e.checkRelayHostConfigured(ctx); hasRelay {
				e.logger.Debug("✓ SMTP relay configured: %s", relayHost)
			} else {
				e.logger.Debug("ℹ No relay host configured (using direct delivery)")
			}
		}
	} else {
		e.logger.Warning("⚠ No MTA configuration file found")
		e.logger.Warning("  Sendmail may queue emails but not deliver them")
	}

	// Check current mail queue
	if queueCount, err := e.checkMailQueue(ctx); err == nil && queueCount > 0 {
		e.logger.Warning("⚠ %d message(s) currently in mail queue (previous emails may be stuck)", queueCount)
		if queueCount > 10 {
			e.logger.Warning("  Large queue detected - check mail server configuration with 'mailq' and /var/log/mail.log")
		}
	}

	e.logger.Debug("=== Building email message ===")

	// Encode subject in Base64 for proper UTF-8 handling
	encodedSubject := base64.StdEncoding.EncodeToString([]byte(subject))

	// Build email headers and body
	var email strings.Builder
	email.WriteString(fmt.Sprintf("To: %s\n", recipient))
	email.WriteString(fmt.Sprintf("From: %s\n", e.config.From))
	email.WriteString(fmt.Sprintf("Subject: =?UTF-8?B?%s?=\n", encodedSubject))
	email.WriteString("MIME-Version: 1.0\n")

	// Decide whether to attach log file
	attachLog := e.config.AttachLogFile && data != nil && strings.TrimSpace(data.LogFilePath) != ""

	if attachLog {
		// Try to read log file; on failure, fall back to plain multipart/alternative
		logPath := strings.TrimSpace(data.LogFilePath)
		content, err := os.ReadFile(logPath)
		if err != nil {
			e.logger.Warning("Failed to read log file for email attachment (%s): %v", logPath, err)
			attachLog = false
		} else {
			mixedBoundary := "mixed_boundary_42"
			altBoundary := "alt_boundary_42"

			email.WriteString(fmt.Sprintf("Content-Type: multipart/mixed; boundary=\"%s\"\n", mixedBoundary))
			email.WriteString("\n")

			// First part: multipart/alternative with text and HTML bodies
			email.WriteString(fmt.Sprintf("--%s\n", mixedBoundary))
			email.WriteString(fmt.Sprintf("Content-Type: multipart/alternative; boundary=\"%s\"\n", altBoundary))
			email.WriteString("\n")

			// Plain text part
			email.WriteString(fmt.Sprintf("--%s\n", altBoundary))
			email.WriteString("Content-Type: text/plain; charset=UTF-8\n")
			email.WriteString("Content-Transfer-Encoding: 8bit\n")
			email.WriteString("\n")
			email.WriteString(textBody)
			email.WriteString("\n\n")

			// HTML part
			email.WriteString(fmt.Sprintf("--%s\n", altBoundary))
			email.WriteString("Content-Type: text/html; charset=UTF-8\n")
			email.WriteString("Content-Transfer-Encoding: 8bit\n")
			email.WriteString("\n")
			email.WriteString(htmlBody)
			email.WriteString("\n\n")

			email.WriteString(fmt.Sprintf("--%s--\n", altBoundary))
			email.WriteString("\n")

			// Second part: log file attachment (Base64 encoded)
			filename := filepath.Base(logPath)
			if filename == "" {
				filename = "backup.log"
			}

			email.WriteString(fmt.Sprintf("--%s\n", mixedBoundary))
			email.WriteString(fmt.Sprintf("Content-Type: text/plain; charset=UTF-8; name=\"%s\"\n", filename))
			email.WriteString(fmt.Sprintf("Content-Disposition: attachment; filename=\"%s\"\n", filename))
			email.WriteString("Content-Transfer-Encoding: base64\n")
			email.WriteString("\n")

			encoded := base64.StdEncoding.EncodeToString(content)
			const maxLineLength = 76
			for i := 0; i < len(encoded); i += maxLineLength {
				end := i + maxLineLength
				if end > len(encoded) {
					end = len(encoded)
				}
				email.WriteString(encoded[i:end])
				email.WriteString("\n")
			}
			email.WriteString("\n")
			email.WriteString(fmt.Sprintf("--%s--\n", mixedBoundary))
		}
	}

	if !attachLog {
		// Fallback / default: simple multipart/alternative (no attachment)
		altBoundary := "boundary42"
		email.WriteString(fmt.Sprintf("Content-Type: multipart/alternative; boundary=\"%s\"\n", altBoundary))
		email.WriteString("\n")

		// Plain text part
		email.WriteString(fmt.Sprintf("--%s\n", altBoundary))
		email.WriteString("Content-Type: text/plain; charset=UTF-8\n")
		email.WriteString("Content-Transfer-Encoding: 8bit\n")
		email.WriteString("\n")
		email.WriteString(textBody)
		email.WriteString("\n\n")

		// HTML part
		email.WriteString(fmt.Sprintf("--%s\n", altBoundary))
		email.WriteString("Content-Type: text/html; charset=UTF-8\n")
		email.WriteString("Content-Transfer-Encoding: 8bit\n")
		email.WriteString("\n")
		email.WriteString(htmlBody)
		email.WriteString("\n\n")

		email.WriteString(fmt.Sprintf("--%s--\n", altBoundary))
	}

	e.logger.Debug("Email message built (%d bytes)", email.Len())

	// ========================================================================
	// SEND EMAIL WITH VERBOSE OUTPUT
	// ========================================================================
	e.logger.Debug("=== Sending email via sendmail ===")

	// Build sendmail arguments
	args := []string{"-t", "-oi"}

	// Add verbose flag if debug logging is enabled
	if e.logger.GetLevel() <= types.LogLevelDebug {
		args = append(args, "-v")
		e.logger.Debug("Verbose mode enabled (-v flag)")
	}

	// Create sendmail command
	cmd := exec.CommandContext(ctx, sendmailPath, args...)
	cmd.Stdin = strings.NewReader(email.String())

	// Capture stdout and stderr separately
	var stdoutBuf, stderrBuf strings.Builder
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	// Execute
	startTime := time.Now()
	err := cmd.Run()
	duration := time.Since(startTime)

	e.logger.Debug("Sendmail command completed in %v", duration)

	// Log stdout if available
	if stdoutBuf.Len() > 0 {
		e.logger.Debug("Sendmail stdout: %s", strings.TrimSpace(stdoutBuf.String()))
	}

	// Log stderr (check for warnings)
	if stderrBuf.Len() > 0 {
		stderrStr := strings.TrimSpace(stderrBuf.String())
		if strings.Contains(strings.ToLower(stderrStr), "warning") {
			e.logger.Warning("Sendmail warning: %s", stderrStr)
		} else {
			e.logger.Debug("Sendmail stderr: %s", stderrStr)
		}
	}

	if err != nil {
		e.logger.Error("❌ Sendmail command failed: %v", err)
		return fmt.Errorf("sendmail failed: %w (stderr: %s)", err, stderrBuf.String())
	}

	// ========================================================================
	// POST-SEND VERIFICATION
	// ========================================================================
	e.logger.Debug("=== Post-send verification ===")

	// Brief pause to let sendmail process the message
	time.Sleep(500 * time.Millisecond)

	// Check queue again to see if message is stuck
	if queueCount, err := e.checkMailQueue(ctx); err == nil {
		if queueCount > 0 {
			e.logger.Debug("ℹ Mail queue size: %d (message may be queued for delivery)", queueCount)
		} else {
			e.logger.Debug("✓ Mail queue is empty (message likely processed)")
		}
	}

	// Check recent mail logs for errors (only in debug mode)
	if e.logger.GetLevel() <= types.LogLevelDebug {
		recentErrors := e.checkRecentMailLogs()
		if len(recentErrors) > 0 && len(recentErrors) <= 5 {
			e.logger.Debug("Recent mail log entries (%d found):", len(recentErrors))
			for _, errLine := range recentErrors {
				if len(errLine) > 200 {
					errLine = errLine[:200] + "..."
				}
				e.logger.Debug("  %s", errLine)
			}
		} else if len(recentErrors) > 5 {
			e.logger.Debug("Recent mail log entries (%d found, showing first 5):", len(recentErrors))
			for i := 0; i < 5; i++ {
				errLine := recentErrors[i]
				if len(errLine) > 200 {
					errLine = errLine[:200] + "..."
				}
				e.logger.Debug("  %s", errLine)
			}
		}
	}

	e.logger.Debug("✅ Email handed off to sendmail successfully")
	e.logger.Info("NOTE: Sendmail exit code 0 means email accepted to queue, not necessarily delivered")
	e.logger.Info("  To verify actual delivery, check: mailq and /var/log/mail.log")

	return nil
}
