#!/usr/bin/env node
// Build the ISG-NIS-Helper guides as .docx from their markdown sources.
//
//   npm install marked docx
//   node build-docs.js                      rebuild all three guides
//   node build-docs.js IN.md OUT.docx "Header title"
//
// Style: Helvetica Neue, black on white, 0.5in margins, running header.
// Plain and neutral on purpose -- this is a technical manual that people
// will print, forward and edit, not a designed document.
//
// Code blocks and inline code stay in a monospace face (Consolas, present
// on both Windows and macOS Office installs). That is deliberate: the
// folder-layout diagrams in Appendix B and the aligned columns in several
// command examples only line up in a fixed-width font. To make the whole
// document one typeface, set FONT_MONO below equal to FONT.
//
// Word has real native "keep with next" (keepNext) and "keep lines
// together" (keepLines) paragraph properties, and `cantSplit` on table
// rows -- the PDF pipeline had to build all of this by hand out of LaTeX
// boxes and penalties (see SKILL.md's "Why this is hard"). Here it's a
// couple of booleans; that's not a shortcut being skipped, it's just
// what Word actually supports natively.

const fs = require('fs');
const path = require('path');
const { marked } = require('marked');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow,
  TableCell, WidthType, BorderStyle, AlignmentType, Header, Footer,
  PageNumber, ShadingType, VerticalAlign,
} = require('docx');

// With no arguments, rebuild every guide in this folder.
const GUIDES = [
  ['Installation.md',    'Installation.docx',    'ISG-NIS-Helper - Installation'],
  ['Usage.md',           'Usage.docx',           'ISG-NIS-Helper - Usage'],
  ['Troubleshooting.md', 'Troubleshooting.docx', 'ISG-NIS-Helper - Troubleshooting'],
];
if (process.argv.length <= 2) {
  const { execFileSync } = require('child_process');
  for (const [md, docx, title] of GUIDES) {
    const src = path.join(__dirname, md);
    if (!fs.existsSync(src)) { console.error('missing ' + md); process.exit(1); }
    execFileSync(process.execPath,
      [__filename, src, path.join(__dirname, docx), title],
      { stdio: 'inherit' });
  }
  process.exit(0);
}

const [, , inputPath, outputPath, headerTitleArg, inkHexArg, paperHexArg] = process.argv;
if (!inputPath || !outputPath) {
  console.error('Usage: build-docs.js [INPUT.md OUTPUT.docx "Header title"]');
  process.exit(1);
}
const HEADER_TITLE = headerTitleArg || '';
const INK = (inkHexArg || '000000').replace('#', '');
const PAPER = (paperHexArg || '').replace('#', '');   // empty = white page
const TABLE_RULE = 'A6A6A6';
const TABLE_HEADER_FILL = 'ECECEC';

const FONT = 'Helvetica Neue';
const FONT_MONO = 'Consolas';        // set to FONT for a single-typeface document
const SIZE_BODY = 21;   // half-points = 10.5pt
const SIZE_TABLE = 19;  // half-points = 9.5pt
const SIZE_CODE = 19;   // half-points = 9.5pt
const SIZE_H1 = 30, SIZE_H2 = 26, SIZE_H3 = 23;

const md = fs.readFileSync(inputPath, 'utf8');
const tokens = marked.lexer(md);

// --- Inline-run building: walk marked's inline token tree, tracking
// bold/italic/code state, and emit TextRun[] ---
// Each ordered list needs its own numbering INSTANCE, or Word continues the
// previous list's count instead of restarting at 1.
let _listInstance = 0;
function nextListInstance() { return ++_listInstance; }

function inlineRuns(inlineTokens, opts = {}) {
  const runs = [];
  const fBold = opts.forceBold;
  const fItalic = opts.forceItalic;
  const walk = (toks, bold, italic, code) => {
    for (const t of toks) {
      switch (t.type) {
        case 'strong':
          walk(t.tokens, true, italic, code);
          break;
        case 'em':
          walk(t.tokens, bold, true, code);
          break;
        case 'codespan':
          runs.push(new TextRun({
            text: t.text, bold: fBold || bold, italics: fItalic || italic, font: FONT_MONO,
            size: opts.size || SIZE_BODY, color: opts.color || INK,
          }));
          break;
        case 'text':
        case 'escape':
          if (t.tokens) { walk(t.tokens, bold, italic, code); }
          else {
            runs.push(new TextRun({
              text: t.text, bold: fBold || bold, italics: fItalic || italic,
              font: opts.font || FONT, size: opts.size || SIZE_BODY,
              color: opts.color || INK,
            }));
          }
          break;
        case 'link':
          walk(t.tokens, bold, italic, code);
          break;
        case 'br':
          runs.push(new TextRun({ text: '', break: 1 }));
          break;
        default:
          if (t.tokens) walk(t.tokens, bold, italic, code);
          else if (t.text) {
            runs.push(new TextRun({
              text: t.text, bold: fBold || bold, italics: fItalic || italic,
              font: opts.font || FONT, size: opts.size || SIZE_BODY,
              color: opts.color || INK,
            }));
          }
      }
    }
  };
  walk(inlineTokens, false, false, false);
  return runs;
}

const HEADING_LEVELS = [HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3];
const HEADING_SIZES = [SIZE_H1, SIZE_H2, SIZE_H3];

// --- Block-level conversion. Returns an array of docx elements
// (Paragraph | Table). `nextIsHeading` lets us set keepNext on the last
// element before a heading follows closely, mirroring the PDF side's
// heading-fusion -- Word's native keepNext makes this trivial. ---
function convertBlocks(blockTokens, extraProps = {}) {
  const out = [];
  for (let i = 0; i < blockTokens.length; i++) {
    const t = blockTokens[i];
    switch (t.type) {
      case 'heading': {
        const level = Math.min(t.depth, 3) - 1;
        out.push(new Paragraph({
          heading: HEADING_LEVELS[level],
          keepNext: true, // never orphan a heading from what follows
          spacing: { before: 320, after: 160 },
          ...extraProps,
          children: inlineRuns(t.tokens, { size: HEADING_SIZES[level], forceBold: true, color: INK }),
        }));
        break;
      }
      case 'paragraph':
        out.push(new Paragraph({
          spacing: { after: 160, line: 240, lineRule: 'auto' },
          ...extraProps,
          children: inlineRuns(t.tokens, extraProps.runOpts),
        }));
        break;
      case 'blockquote': {
        out.push(...convertBlocks(t.tokens, {
          indent: { left: 360 },
          border: { left: { style: BorderStyle.SINGLE, size: 12, color: INK, space: 8 } },
          runOpts: { forceItalic: true },
        }));
        break;
      }
      case 'list': {
        const items = t.items;
        const listInstance = t.ordered ? nextListInstance() : 0;
        items.forEach((item, idx) => {
          out.push(new Paragraph({
            bullet: t.ordered ? undefined : { level: 0 },
            numbering: t.ordered
              ? { reference: 'default-numbering', level: 0, instance: listInstance }
              : undefined,
            keepLines: true,
            keepNext: idx < items.length - 1, // chain list items together
            spacing: { after: 60 },
            ...extraProps,
            children: inlineRuns(item.tokens, extraProps.runOpts),
          }));
        });
        break;
      }
      case 'table': {
        const colCount = t.header.length;
        const headerRow = new TableRow({
          cantSplit: true,
          tableHeader: true,
          children: t.header.map(cell => new TableCell({
            shading: { type: ShadingType.CLEAR, fill: TABLE_HEADER_FILL },
            verticalAlign: VerticalAlign.CENTER,
            children: [new Paragraph({
              keepNext: true,
              children: inlineRuns(cell.tokens, { size: SIZE_TABLE, forceBold: true }),
            })],
          })),
        });
        const bodyRows = t.rows.map((row, rIdx) => new TableRow({
          cantSplit: true,
          children: row.map(cell => new TableCell({
            verticalAlign: VerticalAlign.CENTER,
            children: [new Paragraph({
              // keepNext on every row but the last holds the table together
              keepNext: rIdx < t.rows.length - 1,
              children: inlineRuns(cell.tokens, { size: SIZE_TABLE }),
            })],
          })),
        }));
        out.push(new Table({
          width: { size: 100, type: WidthType.PERCENTAGE },
          borders: {
            top: { style: BorderStyle.SINGLE, size: 4, color: TABLE_RULE },
            bottom: { style: BorderStyle.SINGLE, size: 4, color: TABLE_RULE },
            left: { style: BorderStyle.NONE }, right: { style: BorderStyle.NONE },
            insideHorizontal: { style: BorderStyle.SINGLE, size: 2, color: TABLE_RULE },
            insideVertical: { style: BorderStyle.NONE },
          },
          rows: [headerRow, ...bodyRows],
        }));
        break;
      }
      case 'code': {
        const lines = String(t.text).replace(/\n+$/, '').split('\n');
        lines.forEach((line, i) => {
          out.push(new Paragraph({
            keepLines: true,
            keepNext: i < lines.length - 1,
            spacing: {
              before: i === 0 ? 120 : 0,
              after: i === lines.length - 1 ? 160 : 0,
              line: 240, lineRule: 'exact',
            },
            indent: { left: 360 },
            children: [new TextRun({
              text: line.length ? line : ' ',
              font: FONT_MONO,
              size: SIZE_CODE,
              color: INK,
            })],
          }));
        });
        break;
      }
      case 'hr':
        // No horizontal rules in body text -- spacing only.
        out.push(new Paragraph({ spacing: { after: 320 }, children: [] }));
        break;
      case 'space':
        break;
      default:
        if (t.tokens) out.push(...convertBlocks(t.tokens, extraProps));
    }
  }
  return out;
}

const bodyElements = convertBlocks(tokens);

const doc = new Document({
  styles: {
    default: {
      document: { run: { font: FONT, size: SIZE_BODY, color: INK } },
    },
  },
  numbering: {
    config: [{
      reference: 'default-numbering',
      levels: [{ level: 0, format: 'decimal', text: '%1.', alignment: AlignmentType.START }],
    }],
  },
  ...(PAPER ? { background: { color: PAPER } } : {}),
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 }, // US Letter, DXA
        margin: {
          // A genuine 0.5in of blank paper before the header, body text
          // starting further down still -- same fix as the PDF side's
          // geometry `top`, for the same reason (Word's `header` distance
          // is measured from the page edge, same as LaTeX's headsep
          // model, so a small header value here would otherwise sit
          // inside what should be blank margin).
          top: 1000, bottom: 720, left: 720, right: 720, header: 720, footer: 720,
        },
      },
    },
    headers: {
      default: new Header({
        children: [new Paragraph({
          tabStops: [{ type: 'right', position: 10800 }],
          children: [
            new TextRun({ text: HEADER_TITLE, italics: true, size: 18, color: INK, font: FONT }),
            new TextRun({ text: '\t', size: 18 }),
            new TextRun({ children: [PageNumber.CURRENT], size: 18, color: INK, font: FONT }),
          ],
        })],
      }),
    },
    children: bodyElements,
  }],
});

Packer.toBuffer(doc).then(buffer => {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, buffer);
  console.log(`Wrote ${outputPath}`);
}).catch(err => {
  console.error(err);
  process.exit(1);
});
