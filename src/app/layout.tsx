import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'EZR · e-Zone Computers', description: 'Inventory, sales and accounts management' };
export default function RootLayout({children}:{children:React.ReactNode}) { return <html lang="en"><body>{children}</body></html>; }
