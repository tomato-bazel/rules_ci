// base, but ExampleWeb gains a required field (shape change of an existing export) → AMBIGUOUS → escalate.
export interface ExampleWeb {
  readonly id: string;
  readonly title: string;
  readonly slug: string;
}
export declare function render(x: ExampleWeb): string;
