import { Fragment, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { attachUrl } from '../api'
import { parseOrg, type Block, type Inline } from './parse'

const IMAGE = /\.(png|jpe?g|gif|webp|avif|svg)$/i

type Props = {
  source: string
  /** Titles for [[id:]] targets, so a bare link can name its destination. */
  titles?: Map<string, string | null>
}

export function Org({ source, titles }: Props) {
  const doc = parseOrg(source)
  return (
    <div className="org">
      {doc.blocks.map((block, i) => (
        <Fragment key={i}>{renderBlock(block, titles)}</Fragment>
      ))}
    </div>
  )
}

function renderBlock(block: Block, titles?: Map<string, string | null>): ReactNode {
  switch (block.kind) {
    case 'heading': {
      const Tag = (['h2', 'h3', 'h4', 'h5', 'h6'][Math.min(block.level, 5) - 1] ??
        'h6') as 'h2'
      return (
        <Tag className="org-h" data-level={block.level}>
          {block.todo && <span className="org-todo">{block.todo}</span>}
          {renderInline(block.title, titles)}
          {block.tags.map((tag) => (
            <span key={tag} className="org-tag">
              {tag}
            </span>
          ))}
        </Tag>
      )
    }
    case 'paragraph':
      return <p className="org-p">{renderInline(block.children, titles)}</p>
    case 'list': {
      const Tag = block.ordered ? 'ol' : 'ul'
      return (
        <Tag className="org-list">
          {block.items.map((item, i) => (
            <li key={i}>
              {item.checkbox !== null && (
                <span className="org-box" data-done={item.checkbox}>
                  {item.checkbox ? '✓' : ''}
                </span>
              )}
              {renderInline(item.children, titles)}
            </li>
          ))}
        </Tag>
      )
    }
    case 'pre':
      if (block.variant === 'quote') {
        return <blockquote className="org-quote">{block.text}</blockquote>
      }
      return (
        <pre className="org-pre">
          {block.language && <span className="org-lang">{block.language}</span>}
          <code>{block.text}</code>
        </pre>
      )
    case 'table':
      return (
        <div className="org-table-scroll">
          <table className="org-table">
            <tbody>
              {block.rows.map((row, i) => (
                <tr key={i}>
                  {row.map((cell, j) => (
                    <td key={j}>{cell}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )
  }
}

function renderInline(nodes: Inline[], titles?: Map<string, string | null>): ReactNode {
  return nodes.map((node, i) => (
    <Fragment key={i}>{renderNode(node, titles)}</Fragment>
  ))
}

function renderNode(node: Inline, titles?: Map<string, string | null>): ReactNode {
  switch (node.kind) {
    case 'text':
      return node.text
    case 'code':
      return <code className="org-code">{node.text}</code>
    case 'emphasis': {
      const Tag = node.style === 'bold' ? 'strong' : node.style === 'italic' ? 'em' : 'u'
      return <Tag>{renderInline(node.children, titles)}</Tag>
    }
    case 'link':
      return renderLink(node, titles)
  }
}

function renderLink(
  node: Extract<Inline, { kind: 'link' }>,
  titles?: Map<string, string | null>,
): ReactNode {
  const { target, description } = node

  if (target.startsWith('id:')) {
    const id = target.slice(3)
    const known = titles?.get(id)
    // A link with no description borrows its target's title; failing that
    // the ID is all we have, and a link to nothing says so.
    const label = description ?? known ?? null
    if (label === null && titles?.has(id) === false) {
      return <span className="org-dangling">a note that is no longer here</span>
    }
    return (
      <Link className="org-link" to={`/note/${encodeURIComponent(id)}`}>
        {label ?? id}
      </Link>
    )
  }

  if (target.startsWith('file:') || target.startsWith('attachment:')) {
    const path = target.replace(/^(file|attachment):/, '')
    const name = description ?? path.split('/').pop() ?? path
    if (IMAGE.test(path)) {
      return (
        <a className="org-figure" href={attachUrl(path)}>
          <img src={attachUrl(path)} alt={name} loading="lazy" />
        </a>
      )
    }
    return (
      <a className="org-file" href={attachUrl(path)}>
        {name}
      </a>
    )
  }

  const href = /^[a-z][a-z0-9+.-]*:/i.test(target) ? target : `https://${target}`
  return (
    <a className="org-link" href={href} target="_blank" rel="noreferrer noopener">
      {description ?? target}
    </a>
  )
}
