// import-in-the-middle ships register-hooks.d.ts beside register-hooks.mjs, but
// under "module": "nodenext" TypeScript only looks for a .d.mts next to a .mjs.
// Mirrors that file's declarations.
declare module 'import-in-the-middle/register-hooks.mjs' {
  export type RegisterHooksOptions = {
    include?: Array<string | RegExp>;
    exclude?: Array<string | RegExp>;
    disableCjsSourceStripping?: boolean;
  };

  export function register(options?: RegisterHooksOptions): void;
  export function supportsSyncHooks(): boolean;
}
