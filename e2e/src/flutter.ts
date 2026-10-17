// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, type Locator, type Page } from '@playwright/test';

const BOOT_TIMEOUT = 90_000;

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function cssString(text: string): string {
  return `"${text.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/**
 * One Flutter web client, driven through the accessibility tree it projects.
 *
 * Flutter paints to a canvas, so nothing is scriptable until the placeholder in
 * the DOM is clicked; after that every widget is an <flt-semantics> element whose
 * accessible name is its text content, and text fields are real <input>s whose
 * aria-label is the label followed by the hint.
 */
export class FlutterApp {
  constructor(
    readonly page: Page,
    readonly name: string,
  ) {}

  /** Opens the app and turns the accessibility tree on. */
  async open(url: string): Promise<void> {
    await this.page.goto(url);
    await this.enableSemantics();
  }

  async enableSemantics(): Promise<void> {
    const { page } = this;
    await page.locator('flutter-view, flt-glass-pane').first().waitFor({ state: 'attached', timeout: BOOT_TIMEOUT });
    const tree = page.locator('flt-semantics').first();
    await expect(async () => {
      if (await tree.count()) return;
      // A DOM click, as a screen reader's activation is, not a pointer press at a hidden element.
      await page.evaluate(() => document.querySelector<HTMLElement>('flt-semantics-placeholder')?.click());
      await expect(tree).toBeAttached({ timeout: 2_000 });
    }).toPass({ timeout: BOOT_TIMEOUT });
  }

  /**
   * Nodes named by the label, case-insensitively: a node's name is its aria-label
   * when it has one and its own text otherwise, and both are in use.
   */
  text(label: string): Locator {
    const byAria = this.page.locator(`flt-semantics[aria-label*=${cssString(label)} i]`);
    const byText = this.page
      .locator('flt-semantics:not(:has(flt-semantics))')
      .filter({ hasText: new RegExp(escapeRegExp(label), 'i') });
    return byAria.or(byText);
  }

  /** The node whose whole name is the label, for names that are a prefix of other names. */
  exact(label: string): Locator {
    const byAria = this.page.locator(`flt-semantics[aria-label=${cssString(label)} i]`);
    const byText = this.page
      .locator('flt-semantics:not(:has(flt-semantics))')
      .filter({ hasText: new RegExp(`^\\s*${escapeRegExp(label)}\\s*$`, 'i') });
    return byAria.or(byText);
  }

  /** A text field, found by its label (the aria-label also carries the hint). */
  field(label: string): Locator {
    const sel = `[aria-label*=${cssString(label)} i]`;
    return this.page.locator(`input${sel}, textarea${sel}`).first();
  }

  /**
   * Tappable nodes for a label, tightest match first.
   *
   * A label that merely appears inside a longer name is not offered unless asked for:
   * while a row is still being built its own name can be missing, and "Manage general"
   * would then answer for "general".
   */
  private tappable(label: string, contains: boolean): Locator[] {
    const escaped = escapeRegExp(label);
    const any = 'flt-semantics[flt-tappable], flt-semantics[role="button"]';
    // A row can wrap its own buttons, so text is only matched on the innermost tappable.
    const inner = this.page.locator(any).and(this.page.locator('flt-semantics:not(:has(flt-semantics[flt-tappable]))'));
    const aria = (op: string) => this.page.locator(`flt-semantics[aria-label${op}=${cssString(label)} i]`).and(this.page.locator(any));
    const tiers = [
      aria(''),
      inner.filter({ hasText: new RegExp(`^\\s*${escaped}\\s*(?:\\n|$)`, 'i') }),
      aria('^'),
      inner.filter({ hasText: new RegExp(`^\\s*${escaped}\\b`, 'i') }),
    ];
    if (contains) tiers.push(aria('*'), inner.filter({ hasText: new RegExp(escaped, 'i') }));
    return tiers;
  }

  /** Resolves a tappable label to one node, waiting for it to appear. */
  async control(label: string, { contains = false, timeout = 30_000 } = {}): Promise<Locator> {
    const tiers = this.tappable(label, contains);
    let found: Locator | undefined;
    await expect(async () => {
      for (const tier of tiers) {
        if (await tier.count()) {
          found = tier.first();
          return;
        }
      }
      throw new Error(`${this.name}: no control labelled ${JSON.stringify(label)} yet`);
    }).toPass({ timeout });
    return found!;
  }

  async click(label: string, options: { contains?: boolean } = {}): Promise<void> {
    const node = await this.control(label, options);
    // A DOM click, as a screen reader activates it: a pointer press at the centre can land on a button nested in a row.
    await node.evaluate((el) => (el as HTMLElement).click());
  }

  /**
   * Focuses the field's own input rather than clicking where it looks, then types.
   *
   * Flutter attaches its text-input client a beat after the focus event and resets
   * the value when it does, so text typed too early is silently lost. The value is
   * read back after Flutter has had its frames, and the typing is repeated if it went.
   */
  async type(label: string, value: string): Promise<void> {
    const input = this.field(label);
    // Flutter only builds the <input> for a field that has held focus, so a fresh one is tapped into being.
    const named = this.text(label).first();
    await input.or(named).first().waitFor({ state: 'attached' });
    if (!(await input.count())) await named.click();
    await input.waitFor({ state: 'attached' });
    await expect(async () => {
      const before = await input.inputValue();
      await input.focus();
      await this.flutterFrames();
      await this.page.keyboard.insertText(value);
      await this.flutterFrames();
      await expect(input).toHaveValue(before + value, { timeout: 1_000 });
    }, `${this.name} typing into ${JSON.stringify(label)}`).toPass({ timeout: 15_000 });
  }

  /** Replaces the text of whichever field has focus, for fields that carry no label of their own. */
  async replaceFocusedText(value: string): Promise<void> {
    const field = this.page.locator('input:focus, textarea:focus');
    await expect(field, `${this.name} should have a focused field`).toBeAttached();
    await expect(async () => {
      await this.flutterFrames();
      await this.page.keyboard.press('ControlOrMeta+A');
      await this.page.keyboard.insertText(value);
      await this.flutterFrames();
      await expect(field).toHaveValue(value, { timeout: 1_000 });
    }).toPass({ timeout: 15_000 });
  }

  /** Lets the engine run a few frames, which is what a focus or a tap needs to be acted on. */
  async flutterFrames(count = 3): Promise<void> {
    await this.page.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await new Promise((resolve) => requestAnimationFrame(resolve));
    }, count);
  }

  async see(label: string, timeout = 30_000): Promise<void> {
    await expect(this.text(label).first(), `${this.name} should see ${JSON.stringify(label)}`).toBeAttached({ timeout });
  }

  async seeNo(label: string, timeout = 30_000): Promise<void> {
    await expect(this.text(label), `${this.name} should no longer see ${JSON.stringify(label)}`).toHaveCount(0, { timeout });
  }

  async seeField(label: string, timeout = 30_000): Promise<void> {
    await expect(this.field(label)).toBeAttached({ timeout });
  }

  async waitForUrl(fragment: string, timeout = 60_000): Promise<void> {
    await expect.poll(() => this.page.url(), { timeout, message: `${this.name} should reach ${fragment}` }).toContain(fragment);
  }

  /**
   * Flutter virtualizes lists, so a row below the fold has no node at all.
   * Wheels the pane under `anchor` until the label is in the tree and on screen.
   */
  async scrollUntil(label: string, anchor: string, step = 300, tries = 12): Promise<Locator> {
    const target = this.text(label).first();
    const pane = await this.text(anchor).first().boundingBox();
    if (!pane) throw new Error(`${this.name}: ${JSON.stringify(anchor)} has no box to scroll over`);
    const height = this.page.viewportSize()?.height ?? 900;
    for (let i = 0; i < tries; i++) {
      const box = (await target.count()) ? await target.boundingBox() : null;
      if (box && box.y > 0 && box.y < height - 40) return target;
      await this.page.mouse.move(pane.x + pane.width / 2, Math.min(pane.y + pane.height / 2, height * 0.6));
      await this.page.mouse.wheel(0, step);
      // The wheel starts a scroll animation; the next pass measures where it landed.
      await this.page.waitForTimeout(250);
    }
    throw new Error(`${this.name}: never scrolled ${JSON.stringify(label)} into view`);
  }
}
