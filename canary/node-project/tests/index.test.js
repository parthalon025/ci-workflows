import { describe, it } from 'node:test';
import assert from 'node:assert';
import { add } from '../src/index.js';

describe('add', () => {
  it('adds two numbers', () => {
    assert.strictEqual(add(1, 2), 3);
  });

  it('handles negatives', () => {
    assert.strictEqual(add(-1, 1), 0);
  });
});
