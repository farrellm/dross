import { NavLink, Route, Routes } from 'react-router-dom'
import { NoteList } from './views/NoteList'
import { NoteView } from './views/NoteView'
import { SearchView } from './views/SearchView'
import { GraphView } from './views/GraphView'

export function App() {
  return (
    <>
      <main className="app">
        <Routes>
          <Route path="/" element={<NoteList />} />
          <Route path="/note/:id" element={<NoteView />} />
          <Route path="/search" element={<SearchView />} />
          <Route path="/graph" element={<GraphView />} />
          <Route path="*" element={<NoteList />} />
        </Routes>
      </main>
      <nav className="tabbar">
        <Tab to="/" label="Notes" />
        <Tab to="/search" label="Search" />
        <Tab to="/graph" label="Graph" />
      </nav>
    </>
  )
}

function Tab({ to, label }: { to: string; label: string }) {
  return (
    <NavLink to={to} className="tab" end={to === '/'}>
      {label}
    </NavLink>
  )
}
