import {
  ButtonItem,
  ConfirmModal,
  PanelSection,
  PanelSectionRow,
  TextField,
  ToggleField,
  showModal,
  staticClasses,
} from "@decky/ui";
import {
  addEventListener,
  callable,
  definePlugin,
  removeEventListener,
  toaster,
} from "@decky/api";
import { useEffect, useState } from "react";
import { FaRobot } from "react-icons/fa";

interface Agent {
  pane: string;
  name: string;
  kind: string;
  title: string;
  status: string;
  label: string;
}

interface Snapshot {
  installed: boolean;
  online: boolean;
  agents: Agent[];
}

interface AlertEvent extends Agent {
  event: "transition" | "nag";
}

type Settings = Record<"notify_blocked" | "notify_done" | "nag_blocked", boolean>;

const getSnapshot = callable<[], Snapshot>("get_snapshot");
const promptAgent = callable<[pane: string, text: string], boolean>("prompt_agent");
const getSettings = callable<[], Settings>("get_settings");
const setSetting = callable<[key: keyof Settings, value: boolean], Settings>("set_setting");

// Same palette as the Windows overlay row tints (overlay.ps1 SessionState.Tint).
const STATUS_COLORS: Record<string, string> = {
  working: "#3FB950",
  blocked: "#D29922",
  done: "#7AC2FF",
  idle: "#6E7681",
};

function StatusBadge({ agent }: { agent: Agent }) {
  const color = STATUS_COLORS[agent.status] ?? STATUS_COLORS.idle;
  return <span style={{ color, fontWeight: "bold" }}>● {agent.label}</span>;
}

function PromptModal({ agent, closeModal }: { agent: Agent; closeModal?: () => void }) {
  const [text, setText] = useState("");
  const send = async () => {
    const ok = await promptAgent(agent.pane, text);
    toaster.toast({ title: agent.name, body: ok ? "Prompt sent" : "Could not reach herdr" });
  };
  return (
    <ConfirmModal
      strTitle={`Prompt ${agent.name} (${agent.kind})`}
      strDescription={agent.title}
      strOKButtonText="Send"
      bOKDisabled={!text.trim()}
      onOK={send}
      closeModal={closeModal}
    >
      <TextField value={text} onChange={(e) => setText(e.target.value)} />
    </ConfirmModal>
  );
}

function AgentList() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);

  useEffect(() => {
    getSnapshot().then(setSnapshot);
    const listener = addEventListener<[Snapshot]>("snapshot", setSnapshot);
    return () => {
      removeEventListener("snapshot", listener);
    };
  }, []);

  let message: string | null = null;
  if (!snapshot) message = "Loading…";
  else if (!snapshot.installed) message = "herdr not found. Install it to ~/.local/bin.";
  else if (!snapshot.online) message = "herdr offline. Start `herdr server`.";
  else if (snapshot.agents.length === 0) message = "No agents running.";

  return (
    <PanelSection title={snapshot?.online ? `Agents (${snapshot.agents.length})` : "Agents"}>
      {message ? (
        <PanelSectionRow>
          <div>{message}</div>
        </PanelSectionRow>
      ) : (
        snapshot!.agents.map((agent) => (
          <PanelSectionRow key={agent.pane}>
            <ButtonItem
              layout="below"
              label={`${agent.name} · ${agent.kind}`}
              description={agent.title}
              onClick={() => showModal(<PromptModal agent={agent} />)}
            >
              <StatusBadge agent={agent} />
            </ButtonItem>
          </PanelSectionRow>
        ))
      )}
    </PanelSection>
  );
}

function SettingsSection() {
  const [settings, setSettings] = useState<Settings | null>(null);

  useEffect(() => {
    getSettings().then(setSettings);
  }, []);

  if (!settings) return null;
  const toggle = (key: keyof Settings, label: string) => (
    <PanelSectionRow>
      <ToggleField
        label={label}
        checked={settings[key]}
        onChange={async (value) => setSettings(await setSetting(key, value))}
      />
    </PanelSectionRow>
  );
  return (
    <PanelSection title="Notifications">
      {toggle("notify_blocked", "When an agent needs input")}
      {toggle("nag_blocked", "Remind every minute while waiting")}
      {toggle("notify_done", "When an agent finishes")}
    </PanelSection>
  );
}

function Content() {
  return (
    <>
      <AgentList />
      <SettingsSection />
    </>
  );
}

export default definePlugin(() => {
  // Registered here (not in Content) so alerts arrive while the panel is closed and a game runs.
  const alertListener = addEventListener<[AlertEvent]>("alert", (agent) => {
    const reminder = agent.event === "nag" ? " (still waiting)" : "";
    toaster.toast({
      title: `${agent.name}: ${agent.label}${reminder}`,
      body: agent.title || agent.kind,
      playSound: true,
    });
  });

  return {
    name: "Claude Session Monitor",
    titleView: <div className={staticClasses.Title}>Claude Sessions</div>,
    content: <Content />,
    icon: <FaRobot />,
    onDismount() {
      removeEventListener("alert", alertListener);
    },
  };
});
