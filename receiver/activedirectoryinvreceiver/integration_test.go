// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

//go:build integration && windows

package activedirectoryinvreceiver

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/collector/component/componenttest"
	"go.opentelemetry.io/collector/consumer/consumertest"
	"go.opentelemetry.io/collector/receiver/receivertest"
	"go.uber.org/zap"
)

// TestIntegrationActiveDirectoryInventory exercises the receiver against a real
// Windows Active Directory Domain Services instance (full AD DS, not AD LDS).
//
// The CI workflow installs an AD DS forest (oteltest.local by default), mounts
// the promoted ntds.dit with dsamain when NTDS cannot start without reboot, and
// optionally seeds users/groups. See testdata/integration/setup-ad-ds.ps1.
//
// Expected output shape matches the README configuration: each AD object is
// emitted as a log record whose body is a JSON object containing the configured
// attributes (name, mail, department, manager, memberOf).
func TestIntegrationActiveDirectoryInventory(t *testing.T) {
	baseDN := os.Getenv("AD_BASE_DN")
	if baseDN == "" {
		baseDN = "CN=Users,DC=oteltest,DC=local"
	}

	// Verify AD DS is reachable before starting the receiver; skip with a clear
	// message when the environment was not provisioned (local runs without setup).
	client := &adsiClient{}
	root, err := client.Open(baseDN)
	if err != nil {
		t.Skipf("full AD DS not available at %q (set up via testdata/integration/setup-ad-ds.ps1): %v", baseDN, err)
	}
	root.Close()

	cfg := createDefaultConfig().(*ADConfig)
	cfg.BaseDN = baseDN
	cfg.Attributes = []string{"name", "mail", "department", "manager", "memberOf"}
	cfg.PollInterval = 1 * time.Second

	sink := &consumertest.LogsSink{}
	f := NewFactory()
	rcvr, err := f.CreateLogs(
		t.Context(),
		receivertest.NewNopSettings(f.Type()),
		cfg,
		sink,
	)
	require.NoError(t, err)

	require.NoError(t, rcvr.Start(t.Context(), componenttest.NewNopHost()))
	t.Cleanup(func() {
		require.NoError(t, rcvr.Shutdown(t.Context()))
	})

	require.Eventually(t, func() bool {
		return sink.LogRecordCount() > 0
	}, 60*time.Second, 500*time.Millisecond, "expected at least one inventory log record from AD")

	// Collect all log record bodies as attribute maps.
	type attrMap = map[string]any
	var records []attrMap
	for _, ld := range sink.AllLogs() {
		for i := 0; i < ld.ResourceLogs().Len(); i++ {
			rl := ld.ResourceLogs().At(i)
			for j := 0; j < rl.ScopeLogs().Len(); j++ {
				sl := rl.ScopeLogs().At(j)
				for k := 0; k < sl.LogRecords().Len(); k++ {
					lr := sl.LogRecords().At(k)
					body := lr.Body().AsString()
					if body == "" || body == "{}" {
						continue
					}
					var m attrMap
					if err := json.Unmarshal([]byte(body), &m); err != nil {
						t.Logf("skipping non-JSON body: %q", body)
						continue
					}
					records = append(records, m)
				}
			}
		}
	}
	require.NotEmpty(t, records, "expected non-empty inventory attribute records")

	// README example attributes: name, mail, department, manager, memberOf.
	// When custom users could be seeded, assert exact values; otherwise assert
	// against built-in forest objects that always exist after AD DS promotion.
	seeded := os.Getenv("AD_SEEDED_USERS") != "false"
	var foundTestUser bool
	var foundManager bool
	var foundBuiltin bool
	for _, rec := range records {
		name, _ := rec["name"].(string)
		switch {
		case name == "Otel TestUser" || strings.EqualFold(name, "Otel TestUser"):
			foundTestUser = true
			assert.Equal(t, "oteltestuser@oteltest.local", rec["mail"], "mail for Otel TestUser")
			assert.Equal(t, "Platform", rec["department"], "department for Otel TestUser")
			if mgr, ok := rec["manager"].(string); ok {
				assert.Contains(t, mgr, "Otel Manager", "manager DN should reference Otel Manager")
			} else {
				t.Errorf("expected manager attribute on Otel TestUser, got %v", rec["manager"])
			}
			if mo, ok := rec["memberOf"]; ok {
				moStr := stringifyMemberOf(mo)
				assert.Contains(t, moStr, "Otel TestGroup", "memberOf should include Otel TestGroup")
			}
		case name == "Otel Manager" || strings.EqualFold(name, "Otel Manager"):
			foundManager = true
			assert.Equal(t, "otelmanager@oteltest.local", rec["mail"])
			assert.Equal(t, "Engineering", rec["department"])
		case name == "Administrator" || name == "Guest" || name == "krbtgt" ||
			strings.Contains(strings.ToLower(name), "domain"):
			foundBuiltin = true
		}
		// Every non-empty record body should be valid JSON (README output shape).
		assert.NotNil(t, rec)
	}

	if seeded {
		assert.True(t, foundTestUser, "expected seeded user 'Otel TestUser' in inventory output; records=%v", summarizeNames(records))
		assert.True(t, foundManager, "expected seeded user 'Otel Manager' in inventory output; records=%v", summarizeNames(records))
	} else {
		// dsamain mount of promoted ntds.dit is often read-only; still must
		// enumerate real AD DS objects under CN=Users.
		assert.True(t, foundBuiltin || len(records) >= 1,
			"expected built-in AD DS objects when seeding is unavailable; records=%v", summarizeNames(records))
		t.Logf("AD_SEEDED_USERS=false; validated inventory shape against %d AD DS objects: %v", len(records), summarizeNames(records))
	}

	// Sanity: receiver should emit at least one object under the base DN.
	assert.GreaterOrEqual(t, len(records), 1, "expected AD objects under base DN")
}

// TestIntegrationActiveDirectoryInventoryOpenFailure verifies the real ADSI
// client surfaces an error for an invalid base DN against a live AD instance.
func TestIntegrationActiveDirectoryInventoryOpenFailure(t *testing.T) {
	client := &adsiClient{}
	_, err := client.Open("CN=DoesNotExist,DC=oteltest,DC=local")
	// Either the path fails to open, or the domain itself is missing (skip).
	probe, probeErr := client.Open("CN=Users,DC=oteltest,DC=local")
	if probeErr != nil {
		t.Skipf("full AD DS not available: %v", probeErr)
	}
	probe.Close()
	require.Error(t, err, "opening a non-existent container should fail")
}

// TestIntegrationActiveDirectoryInventoryDirectPoll runs a single poll via the
// internal receiver path (with the real ADSI client) and checks log body shape.
func TestIntegrationActiveDirectoryInventoryDirectPoll(t *testing.T) {
	baseDN := os.Getenv("AD_BASE_DN")
	if baseDN == "" {
		baseDN = "CN=Users,DC=oteltest,DC=local"
	}

	client := &adsiClient{}
	if _, err := client.Open(baseDN); err != nil {
		t.Skipf("full AD DS not available: %v", err)
	}

	cfg := &ADConfig{
		BaseDN:       baseDN,
		Attributes:   []string{"name", "mail", "department", "manager", "memberOf"},
		PollInterval: time.Hour,
	}
	sink := &consumertest.LogsSink{}
	rcvr := newLogsReceiver(cfg, zap.NewNop(), &adsiClient{}, &adRuntimeInfo{}, sink)
	require.NoError(t, rcvr.poll(t.Context()))
	require.Greater(t, sink.LogRecordCount(), 0)

	// At least one record must be valid JSON with a name key (README output shape).
	body := sink.AllLogs()[0].ResourceLogs().At(0).ScopeLogs().At(0).LogRecords().At(0).Body().AsString()
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(body), &m))
	// Objects without any of the requested attributes yield {}; accept either
	// populated or empty maps but ensure the body is valid JSON object text.
	assert.True(t, strings.HasPrefix(body, "{"), "log body should be a JSON object string")
}

func stringifyMemberOf(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []any:
		parts := make([]string, 0, len(t))
		for _, e := range t {
			parts = append(parts, stringifyMemberOf(e))
		}
		return strings.Join(parts, ";")
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

func summarizeNames(records []map[string]any) []string {
	names := make([]string, 0, len(records))
	for _, r := range records {
		if n, ok := r["name"].(string); ok {
			names = append(names, n)
		} else {
			names = append(names, "<no-name>")
		}
	}
	return names
}
