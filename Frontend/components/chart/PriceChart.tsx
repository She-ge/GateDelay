"use client";

import { useState, useMemo } from "react";
import {
  ResponsiveContainer,
  ComposedChart,
  Line,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ReferenceArea,
  Legend,
} from "recharts";
import { format, subHours, subDays, subWeeks, subMonths } from "date-fns";

// ─── Types ────────────────────────────────────────────────────────────────────

export interface PricePoint {
  timestamp: number; // unix ms
  yesPrice: number;  // 0–1
  noPrice: number;   // 0–1
  volume: number;
}

interface PriceChartProps {
  data?: PricePoint[];
  /** Accent colour for YES line */
  yesColor?: string;
  /** Accent colour for NO line */
  noColor?: string;
}

// ─── Time ranges ─────────────────────────────────────────────────────────────

type Range = "1H" | "1D" | "1W" | "1M";

const RANGES: Range[] = ["1H", "1D", "1W", "1M"];

function cutoff(range: Range): number {
  const now = Date.now();
  switch (range) {
    case "1H": return subHours(now, 1).getTime();
    case "1D": return subDays(now, 1).getTime();
    case "1W": return subWeeks(now, 1).getTime();
    case "1M": return subMonths(now, 1).getTime();
  }
}

function xTickFormat(range: Range, ts: number): string {
  switch (range) {
    case "1H": return format(ts, "HH:mm");
    case "1D": return format(ts, "HH:mm");
    case "1W": return format(ts, "EEE");
    case "1M": return format(ts, "MMM d");
  }
}

// ─── Mock data generator ──────────────────────────────────────────────────────

function generateMockData(): PricePoint[] {
  const points: PricePoint[] = [];
  const now = Date.now();
  let yes = 0.5;

  for (let i = 720; i >= 0; i--) {
    yes = Math.min(0.97, Math.max(0.03, yes + (Math.random() - 0.5) * 0.015));
    points.push({
      timestamp: now - i * 5 * 60 * 1000, // every 5 min, 60 h back
      yesPrice: parseFloat(yes.toFixed(4)),
      noPrice: parseFloat((1 - yes).toFixed(4)),
      volume: Math.floor(Math.random() * 800 + 50),
    });
  }
  return points;
}

const MOCK_DATA = generateMockData();

// ─── Custom tooltip ───────────────────────────────────────────────────────────

function ChartTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div
      className="rounded-lg px-3 py-2 text-xs shadow-lg"
      style={{ background: "var(--card)", border: "1px solid var(--border)", color: "var(--foreground)" }}
    >
      <p className="mb-1" style={{ color: "var(--muted)" }}>
        {label ? format(label, "MMM d, HH:mm") : ""}
      </p>
      {payload.map((p: any) => (
        <p key={p.dataKey} style={{ color: p.color }}>
          {p.name}: {p.dataKey === "volume" ? p.value.toLocaleString() : `${(p.value * 100).toFixed(1)}¢`}
        </p>
      ))}
    </div>
  );
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function PriceChart({
  data = MOCK_DATA,
  yesColor = "#22c55e",
  noColor = "#ef4444",
}: PriceChartProps) {
  const [range, setRange] = useState<Range>("1D");

  // Zoom state
  const [zoomLeft, setZoomLeft] = useState<number | null>(null);
  const [zoomRight, setZoomRight] = useState<number | null>(null);
  const [selecting, setSelecting] = useState(false);
  const [domain, setDomain] = useState<[number, number] | null>(null);

  // Filter by time range then optionally by zoom domain
  const filtered = useMemo(() => {
    const from = cutoff(range);
    const base = data.filter((d) => d.timestamp >= from);
    if (!domain) return base;
    return base.filter((d) => d.timestamp >= domain[0] && d.timestamp <= domain[1]);
  }, [data, range, domain]);

  // Reset zoom when range changes
  function handleRangeChange(r: Range) {
    setRange(r);
    setDomain(null);
    setZoomLeft(null);
    setZoomRight(null);
  }

  function handleMouseDown(e: any) {
    if (!e?.activeLabel) return;
    setZoomLeft(e.activeLabel);
    setZoomRight(null);
    setSelecting(true);
  }

  function handleMouseMove(e: any) {
    if (!selecting || !e?.activeLabel) return;
    setZoomRight(e.activeLabel);
  }

  function handleMouseUp() {
    if (selecting && zoomLeft !== null && zoomRight !== null) {
      const [l, r] = zoomLeft < zoomRight ? [zoomLeft, zoomRight] : [zoomRight, zoomLeft];
      if (r - l > 60_000) setDomain([l, r]); // min 1 min window
    }
    setSelecting(false);
    setZoomLeft(null);
    setZoomRight(null);
  }

  const xFormatter = (ts: number) => xTickFormat(range, ts);

  return (
    <div
      className="rounded-xl p-4 space-y-3"
      style={{ background: "var(--card)", border: "1px solid var(--border)" }}
    >
      {/* Header row */}
      <div className="flex items-center justify-between flex-wrap gap-2">
        <p className="text-sm font-semibold" style={{ color: "var(--foreground)" }}>
          Price History
        </p>
        <div className="flex items-center gap-1">
          {domain && (
            <button
              onClick={() => setDomain(null)}
              className="text-xs px-2 py-1 rounded-md mr-1"
              style={{ background: "var(--background)", color: "var(--muted)", border: "1px solid var(--border)" }}
            >
              Reset zoom
            </button>
          )}
          {RANGES.map((r) => (
            <button
              key={r}
              onClick={() => handleRangeChange(r)}
              className="text-xs px-2.5 py-1 rounded-md transition-colors"
              style={{
                background: range === r ? yesColor + "22" : "transparent",
                color: range === r ? yesColor : "var(--muted)",
                border: `1px solid ${range === r ? yesColor + "55" : "var(--border)"}`,
              }}
            >
              {r}
            </button>
          ))}
        </div>
      </div>

      {/* Price chart */}
      <ResponsiveContainer width="100%" height={200}>
        <ComposedChart
          data={filtered}
          margin={{ top: 4, right: 8, left: 0, bottom: 0 }}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
        >
          <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" vertical={false} />
          <XAxis
            dataKey="timestamp"
            type="number"
            scale="time"
            domain={["dataMin", "dataMax"]}
            tickFormatter={xFormatter}
            tick={{ fontSize: 10, fill: "var(--muted)" }}
            tickLine={false}
            axisLine={false}
            minTickGap={40}
          />
          <YAxis
            domain={[0, 1]}
            tickFormatter={(v) => `${(v * 100).toFixed(0)}¢`}
            tick={{ fontSize: 10, fill: "var(--muted)" }}
            tickLine={false}
            axisLine={false}
            width={36}
          />
          <Tooltip content={<ChartTooltip />} />
          <Legend
            iconType="circle"
            iconSize={8}
            wrapperStyle={{ fontSize: 11, paddingTop: 4 }}
            formatter={(value) => <span style={{ color: "var(--muted)" }}>{value}</span>}
          />
          <Line
            type="monotone"
            dataKey="yesPrice"
            name="YES"
            stroke={yesColor}
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
          />
          <Line
            type="monotone"
            dataKey="noPrice"
            name="NO"
            stroke={noColor}
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
          />
          {selecting && zoomLeft !== null && zoomRight !== null && (
            <ReferenceArea
              x1={zoomLeft}
              x2={zoomRight}
              strokeOpacity={0.3}
              fill={yesColor}
              fillOpacity={0.1}
            />
          )}
        </ComposedChart>
      </ResponsiveContainer>

      {/* Volume chart */}
      <ResponsiveContainer width="100%" height={64}>
        <ComposedChart
          data={filtered}
          margin={{ top: 0, right: 8, left: 0, bottom: 0 }}
        >
          <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" vertical={false} />
          <XAxis dataKey="timestamp" type="number" scale="time" domain={["dataMin", "dataMax"]} hide />
          <YAxis
            tick={{ fontSize: 9, fill: "var(--muted)" }}
            tickLine={false}
            axisLine={false}
            width={36}
            tickFormatter={(v) => v >= 1000 ? `${(v / 1000).toFixed(0)}k` : String(v)}
          />
          <Tooltip content={<ChartTooltip />} />
          <Bar dataKey="volume" name="Volume" fill={yesColor} opacity={0.4} radius={[2, 2, 0, 0]} />
        </ComposedChart>
      </ResponsiveContainer>

      <p className="text-xs text-center" style={{ color: "var(--muted)" }}>
        Click and drag on the price chart to zoom · Reset zoom to return
      </p>
    </div>
  );
}
