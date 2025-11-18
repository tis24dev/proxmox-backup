package notify

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os/exec"
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
			err = e.sendViaSendmail(ctx, recipient, subject, htmlBody, textBody)

			// If fallback succeeds, preserve the original relay error for logging
			if err == nil {
				result.Error = relayErr
			}
		}
	} else {
		result.Method = "email-sendmail"
		err = e.sendViaSendmail(ctx, recipient, subject, htmlBody, textBody)
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

// sendViaSendmail sends email via local sendmail command
func (e *EmailNotifier) sendViaSendmail(ctx context.Context, recipient, subject, htmlBody, textBody string) error {
	// Check if sendmail exists
	sendmailPath := "/usr/sbin/sendmail"
	if _, err := exec.LookPath(sendmailPath); err != nil {
		return fmt.Errorf("sendmail not found at %s - please install postfix or configure email relay", sendmailPath)
	}

	// Encode subject in Base64 for proper UTF-8 handling
	encodedSubject := base64.StdEncoding.EncodeToString([]byte(subject))

	// Build email headers and body
	var email strings.Builder
	email.WriteString(fmt.Sprintf("To: %s\n", recipient))
	email.WriteString(fmt.Sprintf("From: %s\n", e.config.From))
	email.WriteString(fmt.Sprintf("Subject: =?UTF-8?B?%s?=\n", encodedSubject))
	email.WriteString("MIME-Version: 1.0\n")
	email.WriteString("Content-Type: multipart/alternative; boundary=\"boundary42\"\n")
	email.WriteString("\n")

	// Plain text part
	email.WriteString("--boundary42\n")
	email.WriteString("Content-Type: text/plain; charset=UTF-8\n")
	email.WriteString("Content-Transfer-Encoding: 8bit\n")
	email.WriteString("\n")
	email.WriteString(textBody)
	email.WriteString("\n\n")

	// HTML part
	email.WriteString("--boundary42\n")
	email.WriteString("Content-Type: text/html; charset=UTF-8\n")
	email.WriteString("Content-Transfer-Encoding: 8bit\n")
	email.WriteString("\n")
	email.WriteString(htmlBody)
	email.WriteString("\n\n")

	email.WriteString("--boundary42--\n")

	// Create sendmail command
	cmd := exec.CommandContext(ctx, sendmailPath, "-t", "-oi")
	cmd.Stdin = strings.NewReader(email.String())

	// Execute
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sendmail failed: %w (output: %s)", err, string(output))
	}

	return nil
}
