import type { Direction } from "../logic/types";

export function ReorderButtons({ onMove, disabled, first, last }: { onMove: (d: Direction) => void; disabled?: boolean; first: boolean; last: boolean }) {
  return (
    <>
      <button aria-label="Sposta su" disabled={disabled || first} onClick={() => onMove("up")}>↑</button>
      <button aria-label="Sposta giù" disabled={disabled || last} onClick={() => onMove("down")}>↓</button>
    </>
  );
}
