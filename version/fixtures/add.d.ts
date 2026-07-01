// base + a NEW exported const (purely additive) → MINOR, deterministic.
export interface ExampleWeb {
  readonly id: string;
  readonly title: string;
}
export declare function render(x: ExampleWeb): string;
export declare const VERSION: string;
