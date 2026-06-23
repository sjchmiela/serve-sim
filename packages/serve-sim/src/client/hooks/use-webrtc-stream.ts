import { useEffect, useRef, useState } from "react";

type IceServer = {
  urls: string[];
  username?: string;
  credential?: string;
};

type WebRtcCodec = "vp8" | "vp9" | "h264";

export type DataChannelTarget = {
  readyState: number;
  send(data: ArrayBuffer): void;
};

const DEFAULT_ICE_SERVERS: IceServer[] = [
  { urls: ["stun:stun.l.google.com:19302"] },
  { urls: ["stun:stun1.l.google.com:19302"] },
];
const ICE_GATHERING_TIMEOUT_MS = 3_000;
const SIGNALING_TIMEOUT_MS = 10_000;

function hasCredentialedTurnServer(servers: IceServer[]): boolean {
  return servers.some((server) =>
    !!server.username &&
    !!server.credential &&
    server.urls.some((url) => {
      const normalized = url.toLowerCase();
      return normalized.startsWith("turn:") || normalized.startsWith("turns:");
    })
  );
}

export function useWebRtcStream({
  url,
  enabled,
  codec = "h264",
  iceServers,
}: {
  url: string;
  enabled: boolean;
  codec?: WebRtcCodec;
  iceServers?: IceServer[];
}) {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const dataChannelRef = useRef<RTCDataChannel | null>(null);

  const dataTarget: DataChannelTarget | null =
    dataChannelRef.current && dataChannelRef.current.readyState === "open"
      ? {
          readyState: 1,
          send: (data) => dataChannelRef.current?.send(data),
        }
      : null;

  useEffect(() => {
    if (!enabled || !url) return;
    if (typeof RTCPeerConnection === "undefined" || typeof RTCRtpReceiver === "undefined") {
      setStream(null);
      setConnected(false);
      setError("WebRTC is not supported in this browser");
      return;
    }

    let stopped = false;
    let pc: RTCPeerConnection | null = null;
    let dc: RTCDataChannel | null = null;
    let offerController: AbortController | null = null;
    let offerTimeout: number | undefined;
    let offerTimedOut = false;
    const servers = iceServers?.length ? iceServers : DEFAULT_ICE_SERVERS;
    setStream(null);
    setConnected(false);
    setError(null);
    dataChannelRef.current = null;

    const waitForIce = (connection: RTCPeerConnection) =>
      new Promise<void>((resolve) => {
        if (connection.iceGatheringState === "complete") {
          resolve();
          return;
        }
        let timeout: number | undefined;
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          connection.removeEventListener("icegatheringstatechange", onState);
          if (timeout !== undefined) window.clearTimeout(timeout);
          resolve();
        };
        const onState = () => {
          if (connection.iceGatheringState !== "complete") return;
          finish();
        };
        connection.addEventListener("icegatheringstatechange", onState);
        timeout = window.setTimeout(finish, ICE_GATHERING_TIMEOUT_MS);
      });

    (async () => {
      try {
        pc = new RTCPeerConnection({
          iceServers: servers,
          iceTransportPolicy: hasCredentialedTurnServer(servers) ? "relay" : "all",
        });
        dc = pc.createDataChannel("input", { ordered: false, maxRetransmits: 0 });
        dataChannelRef.current = dc;
        const videoTransceiver = pc.addTransceiver("video", { direction: "recvonly" });
        const videoCapabilities = RTCRtpReceiver.getCapabilities("video");
        const preferredMimeType = codec === "h264"
          ? "video/H264"
          : codec === "vp9"
            ? "video/VP9"
            : "video/VP8";
        if (videoCapabilities?.codecs.length && "setCodecPreferences" in videoTransceiver) {
          const normalizedPreferredMimeType = preferredMimeType.toLowerCase();
          videoTransceiver.setCodecPreferences([
            ...videoCapabilities.codecs.filter((candidate) =>
              candidate.mimeType.toLowerCase() === normalizedPreferredMimeType
            ),
            ...videoCapabilities.codecs.filter((candidate) =>
              candidate.mimeType.toLowerCase() !== normalizedPreferredMimeType
            ),
          ]);
        }

        dc.onopen = () => {
          if (!stopped) setConnected(true);
        };
        dc.onclose = () => {
          if (!stopped) setConnected(false);
        };
        pc.ontrack = (event) => {
          if (stopped) return;
          setStream(event.streams[0] ?? new MediaStream([event.track]));
          setConnected(true);
          setError(null);
        };
        pc.onconnectionstatechange = () => {
          if (stopped || !pc) return;
          setConnected(pc.connectionState === "connected");
          if (pc.connectionState === "failed") setError("WebRTC connection failed");
        };

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await waitForIce(pc);
        const local = pc.localDescription;
        if (!local) throw new Error("WebRTC offer was not created");
        offerController = new AbortController();
        offerTimeout = window.setTimeout(() => {
          offerTimedOut = true;
          offerController?.abort();
        }, SIGNALING_TIMEOUT_MS);
        let response: Response;
        try {
          response = await fetch(`${url}/webrtc/offer`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            signal: offerController.signal,
            body: JSON.stringify({
              type: local.type,
              sdp: local.sdp,
              codec,
              iceServers: servers,
            }),
          });
        } finally {
          if (offerTimeout !== undefined) {
            window.clearTimeout(offerTimeout);
            offerTimeout = undefined;
          }
        }
        if (!response.ok) throw new Error(`WebRTC offer failed: HTTP ${response.status}`);
        const answer = await response.json() as RTCSessionDescriptionInit;
        await pc.setRemoteDescription(answer);
      } catch (err) {
        if (!stopped) {
          setError(offerTimedOut ? "WebRTC offer timed out" : err instanceof Error ? err.message : String(err));
          setConnected(false);
        }
      }
    })();

    return () => {
      stopped = true;
      if (offerTimeout !== undefined) window.clearTimeout(offerTimeout);
      offerController?.abort();
      dataChannelRef.current = null;
      setStream(null);
      setConnected(false);
      dc?.close();
      pc?.close();
    };
  }, [enabled, url, codec, iceServers]);

  return { stream, dataTarget, connected, error };
}
