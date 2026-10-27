# Notespace

A handwriting notebook app for iPad. These are the words for what a user's notebook is made of and how changes to it happen.

## Notebook content

**Notebook**:
One document the user writes in: an ordered list of pages plus its title, cover and paper.
_Avoid_: Document, file, note

**Page**:
One sheet of paper in a notebook, with a template and the strokes on it.
_Avoid_: Sheet, canvas

**Stroke**:
One continuous mark made with a pen or highlighter, from pen-down to pen-up.
_Avoid_: Line, path, drawing

**Template**:
The printed pattern on a page (blank, lined, dotted, grid, Cornell).
_Avoid_: Background, paper pattern

**Page extension**:
Paper added beside the original page width, on the left and/or the right; every page of a notebook shares it. A side grab (press-hold at a page edge, drag) changes it.
_Avoid_: Margin, canvas size, landscape

## Changes

**Page edit**:
One change to the strokes on one page (add, remove, replace, move/resize, recolor). Every page edit can be inverted exactly.
_Avoid_: Mutation, operation, change set

**Page structure edit**:
Inserting, deleting or moving a whole page.
_Avoid_: Page operation

**Edit pipeline**:
The single ordered path every change to an open notebook takes: saved first, then shown, then added to the history. Changes take effect in the order the user made them.
_Avoid_: Edit queue, session, editor

**History**:
The notebook's undo/redo list. One entry is one user-visible undo step, which may hold several page edits (a long eraser scrub) or page structure edits.
_Avoid_: Undo stack, edit log

**Gesture**:
Everything from the first touch down to the last touch lifted. An eraser gesture is one undo step however many pages it crosses.
_Avoid_: Scrub, session

**Page mirror**:
The copy of the loaded pages the screen draws from; it follows the saved notebook, never leads it.
_Avoid_: Cache, residency (for the concept)

**Echo**:
A saved change coming back to the screen, so what is drawn always matches what is saved.
_Avoid_: Callback, refresh

## Selection

**Selection**:
The strokes the lasso picked on one page, outlined with handles and the context bar. At most one at a time; any new gesture, tool change, undo/redo or tap outside ends it.
_Avoid_: Lasso (for the result), marquee

**Lifted ink**:
Selected strokes drawn off the page while they are dragged, put back once the move or resize is saved.
_Avoid_: Drag preview (for the concept), ghost
