import {
  definePlugin,
  ButtonItem,
  Field,
  PanelSection,
  PanelSectionRow,
} from "@decky/ui";
import { callable } from "@decky/api";
import { VFC, useState, useEffect } from "react";
import { FaSync, FaExclamationTriangle, FaGamepad } from "react-icons/fa";

const getStatus = callable<[], any>("get_status");
const getSystems = callable<[], any>("get_systems");
const getConflicts = callable<[], any>("get_conflicts");
const triggerSyncCall = callable<[{ system_id?: string }], any>("trigger_sync");

const Content: VFC<{}> = () => {
  const [status, setStatus] = useState<any>(null);
  const [systems, setSystems] = useState<string[]>([]);
  const [conflicts, setConflicts] = useState<any[]>([]);
  const [loading, setLoading] = useState<boolean>(false);

  const fetchStatus = async () => {
    try {
      const res = await getStatus();
      setStatus(res);
    } catch (_) {}
  };

  const fetchSystems = async () => {
    try {
      const res = await getSystems();
      if (res?.systems) setSystems(res.systems);
    } catch (_) {}
  };

  const fetchConflicts = async () => {
    try {
      const res = await getConflicts();
      if (res?.conflicts) setConflicts(res.conflicts);
    } catch (_) {}
  };

  useEffect(() => {
    fetchStatus();
    fetchSystems();
    fetchConflicts();
    const interval = setInterval(() => {
      fetchStatus();
      fetchConflicts();
    }, 5000);
    return () => clearInterval(interval);
  }, []);

  const triggerSync = async (systemId?: string) => {
    setLoading(true);
    try {
      await triggerSyncCall({ system_id: systemId });
    } catch (_) {}
    setTimeout(() => {
      fetchStatus();
      setLoading(false);
    }, 1000);
  };

  if (status?.bridge_not_found) {
    return (
      <PanelSection title="Bridge Status">
        <PanelSectionRow>
          <div style={{ color: "#ff8888", display: "flex", alignItems: "center", gap: "10px" }}>
            <FaExclamationTriangle />
            <span>Bridge service not running</span>
          </div>
        </PanelSectionRow>
        <PanelSectionRow>
          <p style={{ fontSize: "0.8em" }}>Run install_autostart.sh from the VaultSync bundle, or go to Settings → Decky Plugin Bridge in the VaultSync app to install the service.</p>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  return (
    <>
      {conflicts.length > 0 && (
        <PanelSection title="Sync Conflicts">
          <PanelSectionRow>
            <div style={{ color: "#ffaa00", display: "flex", alignItems: "center", gap: "10px" }}>
              <FaExclamationTriangle />
              <span>{conflicts.length} conflict(s) detected!</span>
            </div>
          </PanelSectionRow>
          <PanelSectionRow>
            <p style={{ fontSize: "0.8em" }}>Please resolve conflicts in the Desktop app to continue syncing these files.</p>
          </PanelSectionRow>
        </PanelSection>
      )}

      <PanelSection title="VaultSync Dashboard">
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={loading || status?.is_syncing}
            onClick={() => triggerSync()}
          >
            {status?.is_syncing ? "Syncing..." : "Sync All Systems"}
          </ButtonItem>
        </PanelSectionRow>

        <PanelSectionRow>
          <Field
            label={`Status: ${status?.is_online ? "Online" : "Offline"}`}
            description={status?.last_progress || "Idle"}
          />
        </PanelSectionRow>
      </PanelSection>

      {systems.length > 0 && (
        <PanelSection title="Configured Systems">
          {systems.map((sys: string) => (
            <PanelSectionRow key={sys}>
              <ButtonItem
                layout="below"
                disabled={loading || status?.is_syncing}
                onClick={() => triggerSync(sys)}
              >
                <div style={{ display: "flex", alignItems: "center", gap: "10px" }}>
                  <FaGamepad />
                  <span>{sys.toUpperCase()}</span>
                </div>
              </ButtonItem>
            </PanelSectionRow>
          ))}
        </PanelSection>
      )}
    </>
  );
};

export default definePlugin(() => {
  return {
    title: <div>VaultSync</div>,
    content: <Content />,
    icon: <FaSync />,
    onDismount() {},
  };
});
