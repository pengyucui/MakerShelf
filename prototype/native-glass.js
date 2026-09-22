const models = [
  {id:1,title:'旋纹花瓶',en:'Spiral Vase',author:'Layer by Layer',site:'cn',source:'中文站',image:'vase',bg:'#e8ede6',category:'家居装饰',material:'PLA · 亚麻绿',time:'3 小时 20 分',files:3,size:'24.8 MB',saved:true,desc:'让光影沿着曲线流动。细腻的纵向纹理让花瓶在不同光线下呈现柔和层次，适合书桌、窗台与干花陈列。'},
  {id:2,title:'蘑菇氛围灯',en:'Mushroom Lamp',author:'Studio Forma',site:'global',source:'国际站',image:'lamp',bg:'#eee9e1',category:'家居装饰',material:'PLA · 奶油白',time:'6 小时 45 分',files:4,size:'56.2 MB',saved:true,desc:'一盏为角落而生的小灯。褶皱灯罩与圆润底座组成温暖的蘑菇轮廓，分件结构便于搭配不同配色。'},
  {id:3,title:'极简耳机支架',en:'Headphone Stand',author:'Print Practice',site:'local',source:'本地模型',image:'stand',bg:'#e5ebe8',category:'桌面收纳',material:'PETG · 森林绿',time:'2 小时 50 分',files:2,size:'18.6 MB',saved:true,desc:'为桌面留一点呼吸感。简洁的几何支架承托耳机，宽底座提供稳定支撑，顶部弧面减少对头梁的挤压。'},
  {id:4,title:'可动关节小龙',en:'Articulated Dragon',author:'Layer by Layer',site:'global',source:'国际站',image:'dragon',bg:'#e4eadf',category:'趣味玩具',material:'PLA · 苔藓绿',time:'4 小时 10 分',files:2,size:'42.5 MB',saved:false,desc:'一只可以盘在手心里的小龙。分节造型让身体拥有灵活姿态，适合摆在桌边，为日常增加一点乐趣。'},
  {id:5,title:'模块化桌面托盘',en:'Everyday Organizer',author:'Print Practice',site:'cn',source:'中文站',image:'tray',bg:'#f0e5de',category:'桌面收纳',material:'PLA · 陶土橙',time:'3 小时 55 分',files:5,size:'31.4 MB',saved:true,desc:'给那些总是找不到的小东西一个固定位置。分区收纳钥匙、耳机和文具，低矮轮廓让桌面保持整洁。'},
  {id:6,title:'条纹小花盆',en:'Ribbed Planter',author:'Studio Forma',site:'local',source:'本地模型',image:'planter',bg:'#eae7df',category:'家居装饰',material:'PLA · 沙石色',time:'3 小时 15 分',files:3,size:'29.7 MB',saved:true,desc:'一片属于桌面的微型绿洲。竖向纹理搭配柔和圆角，适合小型绿植，模型包含花盆与接水托盘。'}
];

let selected = models[0];
let sourceFilter = 'all';
const grid = document.querySelector('#model-grid');
const inspector = document.querySelector('#inspector');
const resultCount = document.querySelector('#result-count');

function fitPreview() {
  const scale = Math.min((window.innerWidth - 24) / 1440, (window.innerHeight - 24) / 900, 1);
  document.querySelector('#app-window').style.setProperty('--preview-scale', Math.max(scale, .2).toFixed(4));
}

function visibleModels() {
  const query = document.querySelector('#search').value.trim().toLowerCase();
  return models.filter(model => (sourceFilter === 'all' || model.site === sourceFilter) &&
    (!query || `${model.title} ${model.en} ${model.author} ${model.material}`.toLowerCase().includes(query)));
}

function renderGrid() {
  const visible = visibleModels();
  resultCount.textContent = `显示 ${visible.length} / 128`;
  grid.innerHTML = visible.map(model => `
    <article class="model-card ${model.id === selected.id ? 'active' : ''}" data-model="${model.id}" tabindex="0">
      <div class="card-art" style="background:${model.bg}"><img src="assets/${model.image}.svg" alt="${model.title}"><span class="format">${model.site === 'local' ? 'LOCAL' : '3MF'}</span></div>
      <div class="card-info"><h3>${model.title}</h3><p>${model.author}</p><div class="card-meta"><span class="source-badge ${model.site}">${model.source}</span><b>${model.saved ? '已归档' : '未下载'}</b></div></div>
    </article>`).join('') || '<p class="empty">没有找到符合条件的模型。</p>';
}

function renderInspector(tab = 'intro') {
  inspector.innerHTML = `
    <div class="inspector-art" style="background:${selected.bg}"><img src="assets/${selected.image}.svg" alt="${selected.title}"><span class="source-badge ${selected.site}">${selected.source}</span></div>
    <h2>${selected.title}</h2><p class="english">${selected.en}</p>
    <div class="author-row"><span class="avatar">${selected.author[0]}</span>${selected.author}<span class="category">${selected.category}</span></div>
    <div class="inspector-stats"><div><b>${selected.files}</b><small>模型文件</small></div><div><b>${selected.size}</b><small>文件大小</small></div><div><b>${selected.saved ? '已归档' : '未下载'}</b><small>本地状态</small></div></div>
    <div class="segmented inspector-tabs"><button class="${tab === 'intro' ? 'active' : ''}" data-tab="intro">介绍</button><button class="${tab === 'files' ? 'active' : ''}" data-tab="files">文件</button><button class="${tab === 'archive' ? 'active' : ''}" data-tab="archive">归档</button></div>
    <div class="inspector-copy">${tab === 'intro' ? `<h3>关于这个设计</h3><p>${selected.desc}</p><div class="material-row"><span><small>材料</small><b>${selected.material}</b></span><span><small>预估打印</small><b>${selected.time}</b></span></div>` : tab === 'files' ? `<div class="file-list">${Array.from({length:selected.files},(_,i)=>`<div class="file-line">▧ <b>${selected.image}${i ? `_part${i}` : ''}.${i%2 ? 'stl' : '3mf'}</b><span>${i%2 ? 'STL' : '3MF'}</span></div>`).join('')}</div>` : `<h3>完整本地归档</h3><p>模型文件、作者信息、介绍与展示图片保存在同一目录。归档索引使用相对路径，可以整体移动模型库。</p>`}</div>
    <button class="${selected.saved ? 'secondary-button' : 'primary-button'} inspector-action">${selected.saved ? '在访达中显示' : '下载此模型'}</button>`;
}

grid.addEventListener('click', event => {
  const card = event.target.closest('[data-model]');
  if (!card) return;
  selected = models.find(model => model.id === Number(card.dataset.model));
  renderGrid(); renderInspector();
});
grid.addEventListener('keydown', event => { if (event.key === 'Enter') event.target.click(); });
document.querySelectorAll('[data-filter]').forEach(button => button.addEventListener('click', () => {
  sourceFilter = button.dataset.filter;
  document.querySelectorAll('[data-filter]').forEach(item => item.classList.toggle('active', item === button));
  renderGrid();
}));
document.querySelector('#search').addEventListener('input', renderGrid);
document.addEventListener('click', event => { if (event.target.matches('[data-tab]')) renderInspector(event.target.dataset.tab); });

const sheet = document.querySelector('#import-sheet');
document.querySelector('#open-import').addEventListener('click', () => sheet.showModal());
document.querySelector('#theme-toggle').addEventListener('click', () => document.body.classList.toggle('dark'));
document.addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); document.querySelector('#search').focus(); } });

renderGrid();
renderInspector();
fitPreview();
window.addEventListener('resize', fitPreview);
