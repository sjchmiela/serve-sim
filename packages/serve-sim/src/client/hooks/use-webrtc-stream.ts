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
    const servers = iceServers?.length ? iceServers : DEFAULT_ICE_SERVERS;

    const waitForIce = (connection: RTCPeerConnection) =>
      new Promise<void>((resolve) => {
        if (connection.iceGatheringState === "complete") {
          resolve();
          return;
        }
        const onState = () => {
          if (connection.iceGatheringState !== "complete") return;
          connection.removeEventListener("icegatheringstatechange", onState);
          resolve();
        };
        connection.addEventListener("icegatheringstatechange", onState);
      });

    (async () => {
      try {
        pc = new RTCPeerConnection({ iceServers: servers });
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
          videoTransceiver.setCodecPreferences([
            ...videoCapabilities.codecs.filter((candidate) => candidate.mimeType === preferredMimeType),
            ...videoCapabilities.codecs.filter((candidate) => candidate.mimeType !== preferredMimeType),
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
        const response = await fetch(`${url}/webrtc/offer`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            type: local.type,
            sdp: local.sdp,
            codec,
            iceServers: servers,
          }),
        });
        if (!response.ok) throw new Error(`WebRTC offer failed: HTTP ${response.status}`);
        const answer = await response.json() as RTCSessionDescriptionInit;
        await pc.setRemoteDescription(answer);
      } catch (err) {
        if (!stopped) {
          setError(err instanceof Error ? err.message : String(err));
          setConnected(false);
        }
      }
    })();

    return () => {
      stopped = true;
      dataChannelRef.current = null;
      setStream(null);
      setConnected(false);
      dc?.close();
      pc?.close();
    };
  }, [enabled, url, codec, iceServers]);

  return { stream, dataTarget, connected, error };
}
